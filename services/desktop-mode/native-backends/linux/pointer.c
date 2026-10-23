#include "compositor_internal.h"
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_pointer_gestures_v1.h>
#include <wlr/util/region.h>
#include <wlr/backend/libinput.h>
#include <math.h>

struct constraint {
  struct wl_list link;
  struct telar_pointer *pointer;
  struct wlr_pointer_constraint_v1 *source;
  struct wl_listener destroy, region;
};

struct telar_pointer {
  struct telar_server *server;
  struct wlr_relative_pointer_manager_v1 *relative;
  struct wlr_pointer_gestures_v1 *gestures;
  struct wl_list constraints;
  struct constraint *active;
  struct wl_listener new_constraint, pointer_focus, keyboard_focus;
  struct wl_listener swipe_begin, swipe_update, swipe_end;
  struct wl_listener pinch_begin, pinch_update, pinch_end, hold_begin, hold_end;
};

static bool eligible(struct constraint *constraint) {
  struct telar_server *server = constraint->pointer->server;
  struct wlr_seat *seat = server->seat;
  return !server->locked && server->cursor_mode == TELAR_CURSOR_PASSTHROUGH &&
         constraint->source->seat == seat &&
         constraint->source->surface == seat->pointer_state.focused_surface &&
         wlr_surface_get_root_surface(constraint->source->surface) ==
             seat->keyboard_state.focused_surface;
}

static void update(struct telar_pointer *pointer) {
  if (pointer->active && !eligible(pointer->active)) {
    struct constraint *old = pointer->active;
    pointer->active = NULL;
    // One-shot constraints may be destroyed synchronously by this call.
    wlr_pointer_constraint_v1_send_deactivated(old->source);
  }
  if (pointer->active) {
    return;
  }
  struct wlr_seat_pointer_state *seat = &pointer->server->seat->pointer_state;
  struct constraint *constraint;
  wl_list_for_each(constraint, &pointer->constraints, link) {
    if (eligible(constraint) && pixman_region32_contains_point(&constraint->source->region,
                                                               floor(seat->sx),
                                                               floor(seat->sy),
                                                               NULL)) {
      pointer->active = constraint;
      wlr_pointer_constraint_v1_send_activated(constraint->source);
      break;
    }
  }
}

static void pointer_focus(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, pointer_focus);
  update(pointer);
}

static void keyboard_focus(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, keyboard_focus);
  update(pointer);
}

static void constraint_destroy(struct wl_listener *listener, void *data) {
  struct constraint *constraint = wl_container_of(listener, constraint, destroy);
  if (constraint->pointer->active == constraint) {
    constraint->pointer->active = NULL;
  }
  wl_list_remove(&constraint->destroy.link);
  wl_list_remove(&constraint->region.link);
  wl_list_remove(&constraint->link);
  free(constraint);
}

static void constraint_region(struct wl_listener *listener, void *data) {
  struct constraint *constraint = wl_container_of(listener, constraint, region);
  struct telar_pointer *pointer = constraint->pointer;
  struct wlr_seat_pointer_state *seat = &pointer->server->seat->pointer_state;
  if (pointer->active == constraint && !pixman_region32_contains_point(&constraint->source->region,
                                                                       floor(seat->sx),
                                                                       floor(seat->sy),
                                                                       NULL)) {
    pointer->active = NULL;
    wlr_pointer_constraint_v1_send_deactivated(constraint->source);
  }
  update(pointer);
}

static void new_constraint(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, new_constraint);
  struct wlr_pointer_constraint_v1 *source = data;
  struct constraint *constraint = calloc(1, sizeof(*constraint));
  if (!constraint) {
    wl_client_post_no_memory(wl_resource_get_client(source->resource));
    return;
  }
  constraint->pointer = pointer;
  constraint->source = source;
  constraint->destroy.notify = constraint_destroy;
  constraint->region.notify = constraint_region;
  wl_signal_add(&source->events.destroy, &constraint->destroy);
  wl_signal_add(&source->events.set_region, &constraint->region);
  wl_list_insert(&pointer->constraints, &constraint->link);
  update(pointer);
}

static bool
constrain(struct telar_pointer *pointer, struct wlr_input_device *device, double dx, double dy) {
  update(pointer);
  if (!pointer->active) {
    return false;
  }
  struct wlr_pointer_constraint_v1 *source = pointer->active->source;
  if (source->type == WLR_POINTER_CONSTRAINT_V1_LOCKED) {
    return true;
  }
  struct wlr_seat_pointer_state *seat = &pointer->server->seat->pointer_state;
  double x, y;
  if (wlr_region_confine(&source->region,
                         seat->sx,
                         seat->sy,
                         seat->sx + dx,
                         seat->sy + dy,
                         &x,
                         &y)) {
    wlr_cursor_move(pointer->server->cursor, device, x - seat->sx, y - seat->sy);
    return true;
  }
  return false;
}

bool telar_pointer_relative(struct telar_server *server, struct wlr_pointer_motion_event *event) {
  if (!server->locked) {
    wlr_relative_pointer_manager_v1_send_relative_motion(server->pointer->relative,
                                                         server->seat,
                                                         (uint64_t)event->time_msec * 1000,
                                                         event->delta_x,
                                                         event->delta_y,
                                                         event->unaccel_dx,
                                                         event->unaccel_dy);
  }
  return constrain(server->pointer, &event->pointer->base, event->delta_x, event->delta_y);
}

bool telar_pointer_absolute(struct telar_server *server,
                            struct wlr_pointer_motion_absolute_event *event) {
  double x, y;
  wlr_cursor_absolute_to_layout_coords(server->cursor,
                                       &event->pointer->base,
                                       event->x,
                                       event->y,
                                       &x,
                                       &y);
  return constrain(server->pointer,
                   &event->pointer->base,
                   x - server->cursor->x,
                   y - server->cursor->y);
}

void telar_pointer_configure(struct wlr_input_device *device) {
  if (!wlr_input_device_is_libinput(device)) {
    return;
  }
  struct libinput_device *input = wlr_libinput_get_device_handle(device);
  const char *tap = getenv("TELAR_TAP_TO_CLICK");
  if (libinput_device_config_tap_get_finger_count(input)) {
    libinput_device_config_tap_set_enabled(input,
                                           !tap || strcmp(tap, "0") ? LIBINPUT_CONFIG_TAP_ENABLED
                                                                    : LIBINPUT_CONFIG_TAP_DISABLED);
  }
  const char *natural = getenv("TELAR_NATURAL_SCROLL");
  if (natural && libinput_device_config_scroll_has_natural_scroll(input)) {
    libinput_device_config_scroll_set_natural_scroll_enabled(input, strcmp(natural, "0") != 0);
  }
  const char *acceleration = getenv("TELAR_POINTER_ACCEL");
  if (acceleration && libinput_device_config_accel_is_available(input)) {
    char *end;
    double speed = strtod(acceleration, &end);
    if (end != acceleration && !*end && isfinite(speed) && speed >= -1 && speed <= 1) {
      libinput_device_config_accel_set_speed(input, speed);
    }
  }
}

static void swipe_begin(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, swipe_begin);
  struct wlr_pointer_swipe_begin_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  telar_shell_activity(pointer->server);
  wlr_pointer_gestures_v1_send_swipe_begin(pointer->gestures,
                                           pointer->server->seat,
                                           event->time_msec,
                                           event->fingers);
}

static void swipe_update(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, swipe_update);
  struct wlr_pointer_swipe_update_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  wlr_pointer_gestures_v1_send_swipe_update(pointer->gestures,
                                            pointer->server->seat,
                                            event->time_msec,
                                            event->dx,
                                            event->dy);
}

static void swipe_end(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, swipe_end);
  struct wlr_pointer_swipe_end_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  wlr_pointer_gestures_v1_send_swipe_end(pointer->gestures,
                                         pointer->server->seat,
                                         event->time_msec,
                                         event->cancelled);
}

static void pinch_begin(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, pinch_begin);
  struct wlr_pointer_pinch_begin_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  telar_shell_activity(pointer->server);
  wlr_pointer_gestures_v1_send_pinch_begin(pointer->gestures,
                                           pointer->server->seat,
                                           event->time_msec,
                                           event->fingers);
}

static void pinch_update(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, pinch_update);
  struct wlr_pointer_pinch_update_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  wlr_pointer_gestures_v1_send_pinch_update(pointer->gestures,
                                            pointer->server->seat,
                                            event->time_msec,
                                            event->dx,
                                            event->dy,
                                            event->scale,
                                            event->rotation);
}

static void pinch_end(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, pinch_end);
  struct wlr_pointer_pinch_end_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  wlr_pointer_gestures_v1_send_pinch_end(pointer->gestures,
                                         pointer->server->seat,
                                         event->time_msec,
                                         event->cancelled);
}

static void hold_begin(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, hold_begin);
  struct wlr_pointer_hold_begin_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  telar_shell_activity(pointer->server);
  wlr_pointer_gestures_v1_send_hold_begin(pointer->gestures,
                                          pointer->server->seat,
                                          event->time_msec,
                                          event->fingers);
}

static void hold_end(struct wl_listener *listener, void *data) {
  struct telar_pointer *pointer = wl_container_of(listener, pointer, hold_end);
  struct wlr_pointer_hold_end_event *event = data;
  if (pointer->server->locked) {
    return;
  }
  wlr_pointer_gestures_v1_send_hold_end(pointer->gestures,
                                        pointer->server->seat,
                                        event->time_msec,
                                        event->cancelled);
}

bool telar_pointer_init(struct telar_server *server) {
  struct telar_pointer *pointer = calloc(1, sizeof(*pointer));
  if (!pointer) {
    return false;
  }
  pointer->server = server;
  wl_list_init(&pointer->constraints);
  struct wlr_pointer_constraints_v1 *constraints =
      wlr_pointer_constraints_v1_create(server->wl_display);
  pointer->relative = wlr_relative_pointer_manager_v1_create(server->wl_display);
  pointer->gestures = wlr_pointer_gestures_v1_create(server->wl_display);
  if (!constraints || !pointer->relative || !pointer->gestures) {
    free(pointer);
    return false;
  }
  pointer->new_constraint.notify = new_constraint;
  pointer->pointer_focus.notify = pointer_focus;
  pointer->keyboard_focus.notify = keyboard_focus;
  wl_signal_add(&constraints->events.new_constraint, &pointer->new_constraint);
  wl_signal_add(&server->seat->pointer_state.events.focus_change, &pointer->pointer_focus);
  wl_signal_add(&server->seat->keyboard_state.events.focus_change, &pointer->keyboard_focus);
#define GESTURE(name)                                                                              \
  pointer->name.notify = name;                                                                     \
  wl_signal_add(&server->cursor->events.name, &pointer->name)
  GESTURE(swipe_begin);
  GESTURE(swipe_update);
  GESTURE(swipe_end);
  GESTURE(pinch_begin);
  GESTURE(pinch_update);
  GESTURE(pinch_end);
  GESTURE(hold_begin);
  GESTURE(hold_end);
#undef GESTURE
  server->pointer = pointer;
  return true;
}

void telar_pointer_finish(struct telar_server *server) {
  struct telar_pointer *pointer = server->pointer;
  if (!pointer) {
    return;
  }
  wl_list_remove(&pointer->new_constraint.link);
  wl_list_remove(&pointer->pointer_focus.link);
  wl_list_remove(&pointer->keyboard_focus.link);
  wl_list_remove(&pointer->swipe_begin.link);
  wl_list_remove(&pointer->swipe_update.link);
  wl_list_remove(&pointer->swipe_end.link);
  wl_list_remove(&pointer->pinch_begin.link);
  wl_list_remove(&pointer->pinch_update.link);
  wl_list_remove(&pointer->pinch_end.link);
  wl_list_remove(&pointer->hold_begin.link);
  wl_list_remove(&pointer->hold_end.link);
  free(pointer);
  server->pointer = NULL;
}
