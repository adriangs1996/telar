#define _POSIX_C_SOURCE 200809L
// Adapted from wlroots tinywl 0.20.2; see ../../licenses/wlroots.txt.
#include "compositor_internal.h"
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>

static void changed(void *data) {
  struct telar_server *server = data;
  server->changed_idle = NULL;
  if (!server->destroying && server->hooks.changed) {
    telar_shell_visibility(server);
    server->hooks.changed(server->hooks.context);
  }
}

void telar_notify(struct telar_server *server) {
  if (!server->destroying && !server->changed_idle) {
    server->changed_idle =
        wl_event_loop_add_idle(wl_display_get_event_loop(server->wl_display), changed, server);
  }
}

static bool space_visible(struct telar_server *server, uint64_t space) {
  if (!space) {
    return true;
  }
  struct telar_output *output;
  wl_list_for_each(output, &server->outputs, link) {
    if (output->space == space &&
        wlr_output_layout_get(server->output_layout, output->wlr_output)) {
      return true;
    }
  }
  return false;
}

static void update_visibility(struct telar_toplevel *window) {
  bool visible = window->mapped && window->visible && space_visible(window->server, window->space);
  wlr_scene_node_set_enabled(&window->scene_tree->node, visible);
  if (!visible &&
      window->server->seat->keyboard_state.focused_surface == window->xdg_toplevel->base->surface) {
    wlr_seat_keyboard_clear_focus(window->server->seat);
    window->server->focused = 0;
  }
}

static void apply_native(struct telar_toplevel *window);
static void notify_xwindows_visibility(struct telar_server *server);
static void server_new_xwayland(struct wl_listener *listener, void *data);
static void xwayland_ready(struct wl_listener *listener, void *data);
static bool focus_xwindow(struct telar_server *server, struct wlr_surface *surface);

static void deactivate_surface(struct wlr_surface *surface) {
  struct wlr_xdg_toplevel *xdg = wlr_xdg_toplevel_try_from_wlr_surface(surface);
  if (xdg) {
    wlr_xdg_toplevel_set_activated(xdg, false);
  }
  struct wlr_xwayland_surface *xwindow = wlr_xwayland_surface_try_from_wlr_surface(surface);
  if (xwindow) {
    wlr_xwayland_surface_activate(xwindow, false);
  }
}

bool telar_focus_allowed(struct telar_server *server, struct wlr_surface *surface) {
  if (!surface) {
    return false;
  }
  if (server->locked) {
    return wlr_session_lock_surface_v1_try_from_wlr_surface(
               wlr_surface_get_root_surface(surface)) != NULL;
  }
  return !telar_shell_exclusive(server, surface);
}

void telar_focus_surface(struct telar_server *server, struct wlr_surface *surface) {
  if (!telar_focus_allowed(server, surface) ||
      server->seat->keyboard_state.focused_surface == surface) {
    return;
  }
  struct wlr_surface *previous = server->seat->keyboard_state.focused_surface;
  if (previous) {
    deactivate_surface(previous);
  }
  struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
  if (keyboard) {
    if (server->locked) {
      wlr_seat_keyboard_enter(server->seat,
                              surface,
                              keyboard->keycodes,
                              keyboard->num_keycodes,
                              &keyboard->modifiers);
    } else {
      wlr_seat_keyboard_notify_enter(server->seat,
                                     surface,
                                     keyboard->keycodes,
                                     keyboard->num_keycodes,
                                     &keyboard->modifiers);
    }
  }
}

struct telar_output *telar_output_for_space(struct telar_server *server, uint64_t space) {
  struct telar_output *output, *fallback = NULL;
  wl_list_for_each(output, &server->outputs, link) {
    if (!wlr_output_layout_get(server->output_layout, output->wlr_output)) {
      continue;
    }
    if (output->space == space) {
      return output;
    }
    fallback = output;
  }
  return fallback;
}

static void arrange_toplevel(struct telar_toplevel *window) {
  struct wlr_box box = window->placement;
  struct telar_output *output = telar_output_for_space(window->server, window->space);
  if (output && (window->fullscreen || window->maximized)) {
    box = wlr_box_empty(&output->workarea) ? output->usable : output->workarea;
    if (window->fullscreen) {
      wlr_output_layout_get_box(window->server->output_layout, output->wlr_output, &box);
    }
  }
  if (box.width < 1 || box.height < 1) {
    return;
  }
  struct wlr_scene_tree *layer =
      window->fullscreen ? window->server->fullscreen_tree : window->server->layers[window->layer];
  wlr_scene_node_reparent(&window->scene_tree->node, layer);
  wlr_scene_node_set_position(&window->scene_tree->node, box.x, box.y);
  if (window->xdg_toplevel->base->initialized) {
    wlr_xdg_toplevel_set_size(window->xdg_toplevel, box.width, box.height);
  }
}

static void arrange_xwindows(struct telar_server *server);

void telar_arrange_windows(struct telar_server *server) {
  arrange_xwindows(server);
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (window->fullscreen || window->maximized) {
      arrange_toplevel(window);
    }
  }
}

void telar_server_workarea(struct telar_server *server, uint32_t id, struct telar_box box) {
  struct telar_output *output;
  wl_list_for_each(output, &server->outputs, link) {
    if (output->id == id) {
      struct wlr_box area = {box.x, box.y, box.width, box.height};
      if (wlr_box_intersection(&output->workarea, &area, &output->usable)) {
        telar_arrange_windows(server);
      }
      return;
    }
  }
}

static void focus_toplevel(struct telar_toplevel *toplevel) {
  if (toplevel == NULL || !toplevel->mapped || !toplevel->focusable || !toplevel->visible ||
      !space_visible(toplevel->server, toplevel->space)) {
    return;
  }
  struct telar_server *server = toplevel->server;
  if (!telar_focus_allowed(server, toplevel->xdg_toplevel->base->surface)) {
    return;
  }
  struct wlr_seat *seat = server->seat;
  struct wlr_surface *prev_surface = seat->keyboard_state.focused_surface;
  struct wlr_surface *surface = toplevel->xdg_toplevel->base->surface;
  if (prev_surface == surface) {
    return;
  }
  if (prev_surface) {
    deactivate_surface(prev_surface);
  }
  struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);

  server->focus_request = (struct telar_target){0};
  wlr_scene_node_raise_to_top(&toplevel->scene_tree->node);
  server->focused = toplevel->own ? 0 : toplevel->id;
  if (toplevel->space) {
    server->focused_space = toplevel->space;
  }
  telar_notify(server);

  wlr_xdg_toplevel_set_activated(toplevel->xdg_toplevel, true);

  if (keyboard != NULL) {
    wlr_seat_keyboard_notify_enter(seat,
                                   surface,
                                   keyboard->keycodes,
                                   keyboard->num_keycodes,
                                   &keyboard->modifiers);
  }
}

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
  struct telar_keyboard *keyboard = wl_container_of(listener, keyboard, modifiers);

  if (keyboard->server->locked &&
      wlr_input_device_get_virtual_keyboard(&keyboard->wlr_keyboard->base)) {
    return;
  }
  if (telar_input_method_modifiers(keyboard->server, keyboard->wlr_keyboard)) {
    return;
  }
  wlr_seat_set_keyboard(keyboard->server->seat, keyboard->wlr_keyboard);

  wlr_seat_keyboard_notify_modifiers(keyboard->server->seat, &keyboard->wlr_keyboard->modifiers);
}

static void keyboard_handle_key(struct wl_listener *listener, void *data) {
  struct telar_keyboard *keyboard = wl_container_of(listener, keyboard, key);
  struct telar_server *server = keyboard->server;
  struct wlr_keyboard_key_event *event = data;
  struct wlr_seat *seat = server->seat;

  bool virtual = wlr_input_device_get_virtual_keyboard(&keyboard->wlr_keyboard->base) != NULL;
  if (server->locked) {
    if (!virtual && telar_focus_allowed(server, seat->keyboard_state.focused_surface)) {
      telar_shell_activity(server);
      wlr_seat_set_keyboard(seat, keyboard->wlr_keyboard);
      wlr_seat_keyboard_send_key(seat, event->time_msec, event->keycode, event->state);
    }
    return;
  }
  telar_shell_activity(server);
  uint32_t keycode = event->keycode + 8;

  const xkb_keysym_t *syms;
  int nsyms = xkb_state_key_get_syms(keyboard->wlr_keyboard->xkb_state, keycode, &syms);

  if (server->session && nsyms && syms[0] >= XKB_KEY_XF86Switch_VT_1 &&
      syms[0] <= XKB_KEY_XF86Switch_VT_12) {
    if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
      server->hooks.cancel_shortcuts(server->hooks.context);
      wlr_session_change_vt(server->session, syms[0] - XKB_KEY_XF86Switch_VT_1 + 1);
    }
    return;
  }

  uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->wlr_keyboard);
  uint32_t mask = ((modifiers & WLR_MODIFIER_SHIFT) ? TELAR_SHIFT : 0) |
                  ((modifiers & WLR_MODIFIER_ALT) ? TELAR_ALT : 0) |
                  ((modifiers & WLR_MODIFIER_CTRL) ? TELAR_CONTROL : 0) |
                  ((modifiers & WLR_MODIFIER_LOGO) ? TELAR_SUPER : 0);
  const struct telar_key_event key = {
      .code = event->keycode,
      .symbol = nsyms ? syms[0] : 0,
      .unicode = nsyms ? xkb_keysym_to_utf32(syms[0]) : 0,
      .modifiers = mask,
      .pressed = event->state == WL_KEYBOARD_KEY_STATE_PRESSED,
  };
  bool handled = !virtual && server->hooks.key && server->hooks.key(server->hooks.context, &key);
  if (!handled && !virtual && mask == TELAR_SUPER && nsyms && syms[0] == XKB_KEY_l) {
    if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED && server->hooks.lock) {
      server->hooks.lock(server->hooks.context);
    }
    handled = true;
  }
  if (!handled) {
    handled = telar_input_method_key(server, keyboard->wlr_keyboard, event);
  }

  if (!handled) {
    wlr_seat_set_keyboard(seat, keyboard->wlr_keyboard);
    wlr_seat_keyboard_notify_key(seat, event->time_msec, event->keycode, event->state);
  }
}

static void keyboard_handle_destroy(struct wl_listener *listener, void *data) {
  struct telar_keyboard *keyboard = wl_container_of(listener, keyboard, destroy);
  wl_list_remove(&keyboard->modifiers.link);
  wl_list_remove(&keyboard->key.link);
  wl_list_remove(&keyboard->destroy.link);
  wl_list_remove(&keyboard->link);
  struct telar_server *server = keyboard->server;
  if (wlr_seat_get_keyboard(server->seat) == keyboard->wlr_keyboard) {
    struct telar_keyboard *replacement = NULL;
    if (!wl_list_empty(&server->keyboards)) {
      replacement = wl_container_of(server->keyboards.next, replacement, link);
    }
    wlr_seat_set_keyboard(server->seat, replacement ? replacement->wlr_keyboard : NULL);
  }
  uint32_t capabilities = server->seat->capabilities & ~WL_SEAT_CAPABILITY_KEYBOARD;
  if (!wl_list_empty(&server->keyboards)) {
    capabilities |= WL_SEAT_CAPABILITY_KEYBOARD;
  }
  wlr_seat_set_capabilities(server->seat, capabilities);
  free(keyboard);
}

void telar_new_keyboard(struct telar_server *server, struct wlr_input_device *device) {
  struct wlr_keyboard *wlr_keyboard = wlr_keyboard_from_input_device(device);

  struct telar_keyboard *keyboard = calloc(1, sizeof(*keyboard));
  if (!keyboard) {
    return;
  }
  keyboard->server = server;
  keyboard->wlr_keyboard = wlr_keyboard;

  if (!wlr_input_device_get_virtual_keyboard(device)) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!context) {
      free(keyboard);
      return;
    }
    struct xkb_keymap *keymap =
        xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);

    if (!keymap) {
      xkb_context_unref(context);
      free(keyboard);
      return;
    }
    wlr_keyboard_set_keymap(wlr_keyboard, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    wlr_keyboard_set_repeat_info(wlr_keyboard, 25, 600);
  }

  keyboard->modifiers.notify = keyboard_handle_modifiers;
  wl_signal_add(&wlr_keyboard->events.modifiers, &keyboard->modifiers);
  keyboard->key.notify = keyboard_handle_key;
  wl_signal_add(&wlr_keyboard->events.key, &keyboard->key);
  keyboard->destroy.notify = keyboard_handle_destroy;
  wl_signal_add(&device->events.destroy, &keyboard->destroy);

  wlr_seat_set_keyboard(server->seat, keyboard->wlr_keyboard);
  wlr_seat_set_capabilities(server->seat, server->seat->capabilities | WL_SEAT_CAPABILITY_KEYBOARD);

  wl_list_insert(&server->keyboards, &keyboard->link);
}

static void server_new_pointer(struct telar_server *server, struct wlr_input_device *device) {
  telar_pointer_configure(device);
  wlr_cursor_attach_input_device(server->cursor, device);
}

static void server_new_input(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, new_input);
  struct wlr_input_device *device = data;
  switch (device->type) {
  case WLR_INPUT_DEVICE_KEYBOARD:
    telar_new_keyboard(server, device);
    break;
  case WLR_INPUT_DEVICE_POINTER:
    server_new_pointer(server, device);
    break;
  default:
    break;
  }

  uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
  if (!wl_list_empty(&server->keyboards)) {
    caps |= WL_SEAT_CAPABILITY_KEYBOARD;
  }
  wlr_seat_set_capabilities(server->seat, caps);
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, request_cursor);

  struct wlr_seat_pointer_request_set_cursor_event *event = data;
  struct wlr_seat_client *focused_client = server->seat->pointer_state.focused_client;

  if (focused_client == event->seat_client) {
    wlr_cursor_set_surface(server->cursor, event->surface, event->hotspot_x, event->hotspot_y);
  }
}

static void seat_pointer_focus_change(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, pointer_focus_change);

  struct wlr_seat_pointer_focus_change_event *event = data;
  if (event->new_surface == NULL) {
    wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
  }
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, request_set_selection);
  struct wlr_seat_request_set_selection_event *event = data;
  wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static struct telar_toplevel *desktop_toplevel_at(struct telar_server *server,
                                                  struct wlr_surface **surface,
                                                  double *sx,
                                                  double *sy) {
  struct wlr_scene_node *node = NULL;
  if (server->locked) {
    node =
        wlr_scene_node_at(&server->scene->tree.node, server->cursor->x, server->cursor->y, sx, sy);
  } else {
    // A drag icon is rendered above its destination but must never receive input.
    struct wlr_scene_node *layer;
    wl_list_for_each_reverse(layer, &server->desktop_tree->children, link) {
      if (layer != &server->drag_tree->node &&
          (node = wlr_scene_node_at(layer, server->cursor->x, server->cursor->y, sx, sy))) {
        break;
      }
    }
  }
  if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
    return NULL;
  }
  struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
  struct wlr_scene_surface *scene_surface = wlr_scene_surface_try_from_buffer(scene_buffer);
  if (!scene_surface) {
    return NULL;
  }

  *surface = scene_surface->surface;

  struct wlr_scene_tree *tree = node->parent;
  while (tree != NULL && tree->node.data == NULL) {
    tree = tree->node.parent;
  }
  return tree ? tree->node.data : NULL;
}

static void reset_cursor_mode(struct telar_server *server) {
  server->cursor_mode = TELAR_CURSOR_PASSTHROUGH;
  server->grabbed_toplevel = NULL;
}

static void process_cursor_move(struct telar_server *server) {
  struct telar_toplevel *toplevel = server->grabbed_toplevel;
  wlr_scene_node_set_position(&toplevel->scene_tree->node,
                              server->cursor->x - server->grab_x,
                              server->cursor->y - server->grab_y);
  telar_notify(server);
}

static void process_cursor_resize(struct telar_server *server) {
  struct telar_toplevel *toplevel = server->grabbed_toplevel;
  double border_x = server->cursor->x - server->grab_x;
  double border_y = server->cursor->y - server->grab_y;
  int new_left = server->grab_geobox.x;
  int new_right = server->grab_geobox.x + server->grab_geobox.width;
  int new_top = server->grab_geobox.y;
  int new_bottom = server->grab_geobox.y + server->grab_geobox.height;

  if (server->resize_edges & WLR_EDGE_TOP) {
    new_top = border_y;
    if (new_top >= new_bottom) {
      new_top = new_bottom - 1;
    }
  } else if (server->resize_edges & WLR_EDGE_BOTTOM) {
    new_bottom = border_y;
    if (new_bottom <= new_top) {
      new_bottom = new_top + 1;
    }
  }
  if (server->resize_edges & WLR_EDGE_LEFT) {
    new_left = border_x;
    if (new_left >= new_right) {
      new_left = new_right - 1;
    }
  } else if (server->resize_edges & WLR_EDGE_RIGHT) {
    new_right = border_x;
    if (new_right <= new_left) {
      new_right = new_left + 1;
    }
  }

  struct wlr_box *geo_box = &toplevel->xdg_toplevel->base->geometry;
  wlr_scene_node_set_position(&toplevel->scene_tree->node,
                              new_left - geo_box->x,
                              new_top - geo_box->y);

  int new_width = new_right - new_left;
  int new_height = new_bottom - new_top;
  wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, new_width, new_height);
  telar_notify(server);
}

static void process_cursor_motion(struct telar_server *server, uint32_t time) {
  telar_shell_pointer(server);
  if (server->cursor_mode == TELAR_CURSOR_MOVE) {
    process_cursor_move(server);
    return;
  } else if (server->cursor_mode == TELAR_CURSOR_RESIZE) {
    process_cursor_resize(server);
    return;
  }

  double sx, sy;
  struct wlr_seat *seat = server->seat;
  struct wlr_surface *surface = NULL;
  desktop_toplevel_at(server, &surface, &sx, &sy);
  if (!surface) {
    wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
  }
  if (server->locked) {
    if (surface && telar_focus_allowed(server, surface)) {
      wlr_seat_pointer_enter(seat, surface, sx, sy);
      wlr_seat_pointer_send_motion(seat, time, sx, sy);
    } else {
      wlr_seat_pointer_clear_focus(seat);
    }
    return;
  }
  if (surface) {
    wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
    wlr_seat_pointer_notify_motion(seat, time, sx, sy);
  } else {
    wlr_seat_pointer_clear_focus(seat);
  }
}

static void server_cursor_motion(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_motion);
  struct wlr_pointer_motion_event *event = data;

  if (!telar_pointer_relative(server, event)) {
    wlr_cursor_move(server->cursor, &event->pointer->base, event->delta_x, event->delta_y);
  }
  process_cursor_motion(server, event->time_msec);
}

static void server_cursor_motion_absolute(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_motion_absolute);
  struct wlr_pointer_motion_absolute_event *event = data;
  if (!telar_pointer_absolute(server, event)) {
    wlr_cursor_warp_absolute(server->cursor, &event->pointer->base, event->x, event->y);
  }
  process_cursor_motion(server, event->time_msec);
}

static void server_cursor_button(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_button);
  struct wlr_pointer_button_event *event = data;
  if (event->state == WL_POINTER_BUTTON_STATE_PRESSED) {
    server->hooks.cancel_shortcuts(server->hooks.context);
  }
  process_cursor_motion(server, event->time_msec);

  if (server->locked) {
    telar_focus_surface(server, server->seat->pointer_state.focused_surface);
    wlr_seat_pointer_send_button(server->seat, event->time_msec, event->button, event->state);
    return;
  }
  // Focus before sending the press: toolkits use the newest input serial when
  // starting a drag, so a later keyboard-enter must not replace the grab serial.
  if (event->state == WL_POINTER_BUTTON_STATE_PRESSED && !server->seat->drag) {
    double sx, sy;
    struct wlr_surface *surface = NULL;
    struct telar_toplevel *toplevel = desktop_toplevel_at(server, &surface, &sx, &sy);
    if (!telar_shell_focus(server, surface) && !focus_xwindow(server, surface)) {
      focus_toplevel(toplevel);
    }
  }
  wlr_seat_pointer_notify_button(server->seat, event->time_msec, event->button, event->state);
  if (event->state == WL_POINTER_BUTTON_STATE_RELEASED) {
    reset_cursor_mode(server);
  }
}

static void server_cursor_axis(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_axis);
  struct wlr_pointer_axis_event *event = data;
  telar_shell_activity(server);

  wlr_seat_pointer_notify_axis(server->seat,
                               event->time_msec,
                               event->orientation,
                               event->delta,
                               event->delta_discrete,
                               event->source,
                               event->relative_direction);
}

static void server_cursor_frame(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_frame);

  wlr_seat_pointer_notify_frame(server->seat);
}

static void output_frame(struct wl_listener *listener, void *data) {
  struct telar_output *output = wl_container_of(listener, output, frame);
  struct wlr_scene *scene = output->server->scene;

  struct wlr_scene_output *scene_output = wlr_scene_get_scene_output(scene, output->wlr_output);

  wlr_scene_output_commit(scene_output, NULL);

  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  wlr_scene_output_send_frame_done(scene_output, &now);
}

static void output_request_state(struct wl_listener *listener, void *data) {
  struct telar_output *output = wl_container_of(listener, output, request_state);
  const struct wlr_output_event_request_state *event = data;
  wlr_output_commit_state(output->wlr_output, event->state);
  telar_notify(output->server);
}

static void output_commit(struct wl_listener *listener, void *data) {
  struct telar_output *output = wl_container_of(listener, output, commit);
  struct wlr_output_event_commit *event = data;
  if (event->state->committed & (WLR_OUTPUT_STATE_MODE | WLR_OUTPUT_STATE_SCALE |
                                 WLR_OUTPUT_STATE_TRANSFORM | WLR_OUTPUT_STATE_ENABLED)) {
    telar_shell_outputs(output->server);
  }
}

static void output_destroy(struct wl_listener *listener, void *data) {
  struct telar_output *output = wl_container_of(listener, output, destroy);

  wl_list_remove(&output->commit.link);
  wl_list_remove(&output->frame.link);
  wl_list_remove(&output->request_state.link);
  wl_list_remove(&output->destroy.link);
  wl_list_remove(&output->link);
  struct telar_server *server = output->server;
  uint64_t replacement = 0;
  if (!wl_list_empty(&server->outputs)) {
    struct telar_output *next = wl_container_of(server->outputs.next, next, link);
    replacement = next->space;
  }
  if (server->focused_space == output->space) {
    server->focused_space = replacement;
  }

  telar_notify(output->server);
  free(output);
}

static void server_new_output(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, new_output);
  struct wlr_output *wlr_output = data;

  if (!wlr_output_init_render(wlr_output, server->allocator, server->renderer)) {
    return;
  }

  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);

  struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
  if (mode != NULL) {
    wlr_output_state_set_mode(&state, mode);
  }

  bool committed = wlr_output_commit_state(wlr_output, &state);
  wlr_output_state_finish(&state);
  if (!committed) {
    return;
  }

  struct telar_output *output = calloc(1, sizeof(*output));
  if (!output) {
    return;
  }
  output->id = ++server->next_output;
  output->space = output->id;
  if (!server->focused_space) {
    server->focused_space = output->space;
  }
  output->wlr_output = wlr_output;
  output->server = server;

  output->commit.notify = output_commit;
  wl_signal_add(&wlr_output->events.commit, &output->commit);
  output->frame.notify = output_frame;
  wl_signal_add(&wlr_output->events.frame, &output->frame);

  output->request_state.notify = output_request_state;
  wl_signal_add(&wlr_output->events.request_state, &output->request_state);

  output->destroy.notify = output_destroy;
  wl_signal_add(&wlr_output->events.destroy, &output->destroy);

  wl_list_insert(&server->outputs, &output->link);

  struct wlr_output_layout_output *l_output =
      wlr_output_layout_add_auto(server->output_layout, wlr_output);
  struct wlr_scene_output *scene_output = wlr_scene_output_create(server->scene, wlr_output);
  wlr_scene_output_layout_add_output(server->scene_layout, l_output, scene_output);
  telar_shell_outputs(server);
  telar_notify(server);
}

static void xdg_toplevel_map(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, map);

  toplevel->mapped = true;
  if (!toplevel->space && !toplevel->own) {
    toplevel->space = toplevel->server->focused_space;
  }
  apply_native(toplevel);
  update_visibility(toplevel);
  if (!toplevel->own || toplevel->server->focus_request.resource == toplevel->resource) {
    focus_toplevel(toplevel);
  }
  telar_notify(toplevel->server);
}

static void xdg_toplevel_unmap(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, unmap);

  if (toplevel == toplevel->server->grabbed_toplevel) {
    reset_cursor_mode(toplevel->server);
  }

  toplevel->mapped = false;
  update_visibility(toplevel);
  telar_notify(toplevel->server);
}

static void xdg_toplevel_commit(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, commit);

  if (toplevel->xdg_toplevel->base->initial_commit) {
    wlr_xdg_toplevel_set_wm_capabilities(toplevel->xdg_toplevel,
                                         WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE |
                                             WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN);
    wlr_xdg_toplevel_set_size(toplevel->xdg_toplevel, initial_window_width, initial_window_height);
    wlr_xdg_toplevel_set_fullscreen(toplevel->xdg_toplevel, toplevel->fullscreen);
    wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, toplevel->maximized);
    arrange_toplevel(toplevel);
    apply_native(toplevel);
  }
  struct wlr_box box = toplevel->xdg_toplevel->base->geometry;
  if (box.width != toplevel->last_width || box.height != toplevel->last_height) {
    toplevel->last_width = box.width;
    toplevel->last_height = box.height;
    telar_notify(toplevel->server);
  }
}

static void xdg_toplevel_destroy(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, destroy);

  wl_list_remove(&toplevel->map.link);
  wl_list_remove(&toplevel->unmap.link);
  wl_list_remove(&toplevel->commit.link);
  wl_list_remove(&toplevel->destroy.link);
  wl_list_remove(&toplevel->request_move.link);
  wl_list_remove(&toplevel->request_resize.link);
  wl_list_remove(&toplevel->request_maximize.link);
  wl_list_remove(&toplevel->request_fullscreen.link);

  wl_list_remove(&toplevel->title.link);
  wl_list_remove(&toplevel->app_id.link);
  wl_list_remove(&toplevel->link);
  if (toplevel->own) {
    struct native_placement *entry, *temporary;
    wl_list_for_each_safe(entry, temporary, &toplevel->server->natives, link) {
      if (entry->value.target.resource == toplevel->resource) {
        wl_list_remove(&entry->link);
        free(entry);
      }
    }
  }
  if (toplevel->server->focused == toplevel->id) {
    toplevel->server->focused = 0;
  }
  telar_notify(toplevel->server);
  free(toplevel);
}

static void
begin_interactive(struct telar_toplevel *toplevel, enum telar_cursor_mode mode, uint32_t edges) {
  struct telar_server *server = toplevel->server;

  server->grabbed_toplevel = toplevel;
  server->cursor_mode = mode;

  if (mode == TELAR_CURSOR_MOVE) {
    server->grab_x = server->cursor->x - toplevel->scene_tree->node.x;
    server->grab_y = server->cursor->y - toplevel->scene_tree->node.y;
  } else {
    struct wlr_box *geo_box = &toplevel->xdg_toplevel->base->geometry;

    double border_x = (toplevel->scene_tree->node.x + geo_box->x) +
                      ((edges & WLR_EDGE_RIGHT) ? geo_box->width : 0);
    double border_y = (toplevel->scene_tree->node.y + geo_box->y) +
                      ((edges & WLR_EDGE_BOTTOM) ? geo_box->height : 0);
    server->grab_x = server->cursor->x - border_x;
    server->grab_y = server->cursor->y - border_y;

    server->grab_geobox = *geo_box;
    server->grab_geobox.x += toplevel->scene_tree->node.x;
    server->grab_geobox.y += toplevel->scene_tree->node.y;

    server->resize_edges = edges;
  }
}

static void xdg_toplevel_request_move(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, request_move);
  struct wlr_xdg_toplevel_move_event *event = data;
  if (wlr_seat_validate_pointer_grab_serial(toplevel->server->seat,
                                            toplevel->xdg_toplevel->base->surface,
                                            event->serial)) {
    begin_interactive(toplevel, TELAR_CURSOR_MOVE, 0);
  }
}

static void xdg_toplevel_request_resize(struct wl_listener *listener, void *data) {
  struct wlr_xdg_toplevel_resize_event *event = data;
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, request_resize);
  if (wlr_seat_validate_pointer_grab_serial(toplevel->server->seat,
                                            toplevel->xdg_toplevel->base->surface,
                                            event->serial)) {
    begin_interactive(toplevel, TELAR_CURSOR_RESIZE, event->edges);
  }
}

static void xdg_toplevel_request_maximize(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, request_maximize);
  toplevel->maximized = toplevel->xdg_toplevel->requested.maximized;
  if (toplevel->xdg_toplevel->base->initialized) {
    wlr_xdg_toplevel_set_maximized(toplevel->xdg_toplevel, toplevel->maximized);
    arrange_toplevel(toplevel);
  }
}

static void xdg_toplevel_request_fullscreen(struct wl_listener *listener, void *data) {
  struct telar_toplevel *toplevel = wl_container_of(listener, toplevel, request_fullscreen);
  toplevel->fullscreen = toplevel->xdg_toplevel->requested.fullscreen;
  if (toplevel->xdg_toplevel->base->initialized) {
    wlr_xdg_toplevel_set_fullscreen(toplevel->xdg_toplevel, toplevel->fullscreen);
    arrange_toplevel(toplevel);
  }
}

static void toplevel_title(struct wl_listener *listener, void *data) {
  struct telar_toplevel *window = wl_container_of(listener, window, title);
  telar_notify(window->server);
}

static void toplevel_app_id(struct wl_listener *listener, void *data) {
  struct telar_toplevel *window = wl_container_of(listener, window, app_id);
  telar_notify(window->server);
}

static void server_new_xdg_toplevel(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, new_xdg_toplevel);
  struct wlr_xdg_toplevel *xdg_toplevel = data;

  if (wl_list_length(&server->toplevels) >= max_windows) {
    wl_client_post_no_memory(wl_resource_get_client(xdg_toplevel->resource));
    return;
  }
  struct telar_toplevel *toplevel = calloc(1, sizeof(*toplevel));
  if (!toplevel) {
    wl_client_post_no_memory(wl_resource_get_client(xdg_toplevel->resource));
    return;
  }
  toplevel->id = ++server->next_window;
  toplevel->resource = wl_resource_get_id(xdg_toplevel->base->surface->resource);
  wl_client_get_credentials(wl_resource_get_client(xdg_toplevel->resource),
                            &toplevel->pid,
                            NULL,
                            NULL);
  toplevel->own = toplevel->pid == getpid();
  toplevel->visible = !toplevel->own;
  toplevel->focusable = true;
  toplevel->layer = TELAR_WINDOWS;
  toplevel->placement = (struct wlr_box){0, 0, initial_window_width, initial_window_height};
  wl_list_insert(&server->toplevels, &toplevel->link);
  toplevel->server = server;
  toplevel->xdg_toplevel = xdg_toplevel;
  toplevel->scene_tree =
      wlr_scene_xdg_surface_create(server->layers[TELAR_WINDOWS], xdg_toplevel->base);
  if (!toplevel->scene_tree) {
    wl_list_remove(&toplevel->link);
    free(toplevel);
    wl_client_post_no_memory(wl_resource_get_client(xdg_toplevel->resource));
    return;
  }
  toplevel->scene_tree->node.data = toplevel;
  xdg_toplevel->base->data = toplevel->scene_tree;
  wlr_scene_node_set_enabled(&toplevel->scene_tree->node, false);
  toplevel->title.notify = toplevel_title;
  wl_signal_add(&xdg_toplevel->events.set_title, &toplevel->title);
  toplevel->app_id.notify = toplevel_app_id;
  wl_signal_add(&xdg_toplevel->events.set_app_id, &toplevel->app_id);

  toplevel->map.notify = xdg_toplevel_map;
  wl_signal_add(&xdg_toplevel->base->surface->events.map, &toplevel->map);
  toplevel->unmap.notify = xdg_toplevel_unmap;
  wl_signal_add(&xdg_toplevel->base->surface->events.unmap, &toplevel->unmap);
  toplevel->commit.notify = xdg_toplevel_commit;
  wl_signal_add(&xdg_toplevel->base->surface->events.commit, &toplevel->commit);

  toplevel->destroy.notify = xdg_toplevel_destroy;
  wl_signal_add(&xdg_toplevel->events.destroy, &toplevel->destroy);

  toplevel->request_move.notify = xdg_toplevel_request_move;
  wl_signal_add(&xdg_toplevel->events.request_move, &toplevel->request_move);
  toplevel->request_resize.notify = xdg_toplevel_request_resize;
  wl_signal_add(&xdg_toplevel->events.request_resize, &toplevel->request_resize);
  toplevel->request_maximize.notify = xdg_toplevel_request_maximize;
  wl_signal_add(&xdg_toplevel->events.request_maximize, &toplevel->request_maximize);
  toplevel->request_fullscreen.notify = xdg_toplevel_request_fullscreen;
  wl_signal_add(&xdg_toplevel->events.request_fullscreen, &toplevel->request_fullscreen);
}

static void xdg_popup_commit(struct wl_listener *listener, void *data) {
  struct telar_popup *popup = wl_container_of(listener, popup, commit);
  struct wlr_surface *root = popup->xdg_popup->parent;
  for (size_t depth = 0; root && depth < max_windows; ++depth) {
    struct wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(root);
    if (!xdg || xdg->role != WLR_XDG_SURFACE_ROLE_POPUP) {
      break;
    }
    root = xdg->popup->parent;
  }
  struct wlr_scene_tree *tree = telar_surface_tree(popup->server, root);
  int x = 0, y = 0;
  wlr_scene_node_coords(&(tree ? tree : popup->parent)->node, &x, &y);
  struct telar_output *output = telar_output_for_space(popup->server, popup->server->focused_space);
  if (output) {
    struct wlr_box box;
    wlr_output_layout_get_box(popup->server->output_layout, output->wlr_output, &box);
    box.x -= x;
    box.y -= y;
    wlr_xdg_popup_unconstrain_from_box(popup->xdg_popup, &box);
  }

  if (popup->xdg_popup->base->initial_commit) {
    wlr_xdg_surface_schedule_configure(popup->xdg_popup->base);
  }
}

static void xdg_popup_destroy(struct wl_listener *listener, void *data) {
  struct telar_popup *popup = wl_container_of(listener, popup, destroy);

  wl_list_remove(&popup->commit.link);
  wl_list_remove(&popup->destroy.link);

  free(popup);
}

void telar_create_popup(struct telar_server *server,
                        struct wlr_xdg_popup *xdg_popup,
                        struct wlr_scene_tree *parent_tree) {
  if (xdg_popup->base->data) {
    return;
  }
  struct telar_popup *popup = calloc(1, sizeof(*popup));
  if (!popup) {
    wl_client_post_no_memory(wl_resource_get_client(xdg_popup->resource));
    return;
  }
  popup->server = server;
  popup->parent = parent_tree;
  popup->xdg_popup = xdg_popup;
  xdg_popup->base->data = wlr_scene_xdg_surface_create(parent_tree, xdg_popup->base);
  if (!xdg_popup->base->data) {
    free(popup);
    wl_client_post_no_memory(wl_resource_get_client(xdg_popup->resource));
    return;
  }
  popup->commit.notify = xdg_popup_commit;
  wl_signal_add(&xdg_popup->base->surface->events.commit, &popup->commit);
  popup->destroy.notify = xdg_popup_destroy;
  wl_signal_add(&xdg_popup->events.destroy, &popup->destroy);
}

static void server_new_xdg_popup(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, new_xdg_popup);
  struct wlr_xdg_popup *popup = data;
  if (popup->base->data) {
    return;
  }
  struct wlr_scene_tree *parent = telar_surface_tree(server, popup->parent);
  if (parent) {
    telar_create_popup(server, popup, parent);
  } else if (popup->parent) {
    wlr_xdg_popup_destroy(popup);
  }
}

struct telar_xwindow {
  struct wl_list link;
  struct telar_server *server;
  struct wlr_xwayland_surface *surface;
  struct wlr_scene_tree *tree;
  uint32_t id;
  uint64_t space;
  bool visible;
  bool fullscreen, maximized;
  struct wlr_box placement;
  struct wl_listener fullscreen_request, maximize_request, activate_request;
  struct wl_listener associate, dissociate, map, unmap, destroy, configure, title, class_name,
      geometry;
};

static void arrange_xwindow(struct telar_xwindow *window) {
  struct wlr_box box = window->placement;
  struct telar_output *output = telar_output_for_space(window->server, window->space);
  if (output && (window->fullscreen || window->maximized)) {
    box = wlr_box_empty(&output->workarea) ? output->usable : output->workarea;
    if (window->fullscreen) {
      wlr_output_layout_get_box(window->server->output_layout, output->wlr_output, &box);
    }
  }
  if (box.width < 1 || box.height < 1) {
    return;
  }
  wlr_xwayland_surface_configure(window->surface, box.x, box.y, box.width, box.height);
  if (window->tree) {
    wlr_scene_node_reparent(&window->tree->node,
                            window->fullscreen ? window->server->fullscreen_tree
                                               : window->server->layers[TELAR_WINDOWS]);
    wlr_scene_node_set_position(&window->tree->node, box.x, box.y);
  }
}

static void arrange_xwindows(struct telar_server *server) {
  struct telar_xwindow *window;
  wl_list_for_each(window, &server->xwindows, link) {
    if (window->fullscreen || window->maximized) {
      arrange_xwindow(window);
    }
  }
}

static void xwindow_activate(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, activate_request);
  telar_activate_surface(window->server, window->surface->surface);
}

static void xwindow_fullscreen(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, fullscreen_request);
  window->fullscreen = window->surface->fullscreen;
  wlr_xwayland_surface_set_fullscreen(window->surface, window->fullscreen);
  arrange_xwindow(window);
  telar_notify(window->server);
}

static void xwindow_maximize(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, maximize_request);
  window->maximized = window->surface->maximized_horz && window->surface->maximized_vert;
  wlr_xwayland_surface_set_maximized(window->surface, window->maximized, window->maximized);
  arrange_xwindow(window);
  telar_notify(window->server);
}

struct wlr_scene_tree *telar_surface_tree(struct telar_server *server,
                                          struct wlr_surface *surface) {
  if (!surface) {
    return NULL;
  }
  surface = wlr_surface_get_root_surface(surface);
  struct wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
  if (xdg) {
    return xdg->data;
  }
  struct wlr_layer_surface_v1 *layer = wlr_layer_surface_v1_try_from_wlr_surface(surface);
  if (layer) {
    return layer->data;
  }
  struct telar_xwindow *window;
  wl_list_for_each(window, &server->xwindows, link) {
    if (window->surface->surface == surface) {
      return window->tree;
    }
  }
  return NULL;
}

void telar_restore_focus(struct telar_server *server) {
  if (server->locked || server->destroying || server->seat->keyboard_state.focused_surface) {
    return;
  }
  struct telar_toplevel *window;
  wl_list_for_each_reverse(window, &server->toplevels, link) {
    focus_toplevel(window);
    if (server->seat->keyboard_state.focused_surface) {
      return;
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (focus_xwindow(server, xwindow->surface->surface)) {
      return;
    }
  }
}

static void xwindow_visibility(struct telar_xwindow *window) {
  if (!window->tree) {
    return;
  }
  bool enabled = window->surface->surface->mapped && window->visible &&
                 space_visible(window->server, window->space);
  if (window->surface->override_redirect) {
    struct wlr_xwayland_surface *parent = window->surface->parent;
    size_t depth = 0;
    while (enabled && parent) {
      if (++depth > max_windows) {
        enabled = false;
        break;
      }
      const struct telar_xwindow *owner = parent->data;
      if (owner) {
        enabled = owner->visible && parent->surface && parent->surface->mapped &&
                  space_visible(window->server, owner->space);
      }
      parent = parent->parent;
    }
  }
  wlr_scene_node_set_enabled(&window->tree->node, enabled);
  if (!enabled &&
      window->server->seat->keyboard_state.focused_surface == window->surface->surface) {
    wlr_seat_keyboard_clear_focus(window->server->seat);
    window->server->focused = 0;
  }
}

static void notify_xwindows_visibility(struct telar_server *server) {
  struct telar_xwindow *window;
  wl_list_for_each(window, &server->xwindows, link) {
    xwindow_visibility(window);
  }
}

static bool focus_xwindow(struct telar_server *server, struct wlr_surface *surface) {
  if (!surface || !telar_focus_allowed(server, surface)) {
    return false;
  }
  struct telar_xwindow *window;
  wl_list_for_each(window, &server->xwindows, link) {
    if (window->surface->surface != surface || !window->tree || !window->tree->node.enabled) {
      continue;
    }
    if (window->surface->override_redirect &&
        !wlr_xwayland_surface_override_redirect_wants_focus(window->surface)) {
      return true;
    }
    struct wlr_surface *previous = server->seat->keyboard_state.focused_surface;
    if (previous && previous != surface) {
      deactivate_surface(previous);
    }
    wlr_scene_node_raise_to_top(&window->tree->node);
    wlr_xwayland_surface_activate(window->surface, true);
    struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
    if (keyboard) {
      wlr_seat_keyboard_notify_enter(server->seat,
                                     surface,
                                     keyboard->keycodes,
                                     keyboard->num_keycodes,
                                     &keyboard->modifiers);
    }
    server->focus_request = (struct telar_target){0};
    server->focused = window->id;
    server->focused_space = window->space;
    telar_notify(server);
    return true;
  }
  return false;
}

static void xwindow_map(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, map);
  if (!window->space) {
    window->space = window->server->focused_space;
  }
  if (window->surface->parent && window->surface->parent->data) {
    struct telar_xwindow *parent = window->surface->parent->data;
    window->space = parent->space;
  }
  if (window->fullscreen || window->maximized) {
    arrange_xwindow(window);
  }
  notify_xwindows_visibility(window->server);
  if (!window->surface->override_redirect) {
    focus_xwindow(window->server, window->surface->surface);
  }
  telar_notify(window->server);
}

static void xwindow_unmap(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, unmap);
  notify_xwindows_visibility(window->server);
  telar_notify(window->server);
}

static void xwindow_associate(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, associate);
  // The subsurface helper dies with wl_surface, before XWayland's dissociate
  // event. Own a separate parent so either teardown order is safe.
  window->tree = wlr_scene_tree_create(window->server->layers[TELAR_WINDOWS]);
  if (!window->tree || !wlr_scene_subsurface_tree_create(window->tree, window->surface->surface)) {
    if (window->tree) {
      wlr_scene_node_destroy(&window->tree->node);
      window->tree = NULL;
    }
    return;
  }
  wlr_scene_node_set_position(&window->tree->node, window->surface->x, window->surface->y);
  window->map.notify = xwindow_map;
  wl_signal_add(&window->surface->surface->events.map, &window->map);
  window->unmap.notify = xwindow_unmap;
  wl_signal_add(&window->surface->surface->events.unmap, &window->unmap);
  xwindow_visibility(window);
}

static void xwindow_dissociate(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, dissociate);
  if (!window->tree) {
    return;
  }
  wl_list_remove(&window->map.link);
  wl_list_remove(&window->unmap.link);
  wlr_scene_node_destroy(&window->tree->node);
  window->tree = NULL;
  telar_notify(window->server);
}

static void xwindow_destroy(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, destroy);
  xwindow_dissociate(&window->dissociate, NULL);
  wl_list_remove(&window->activate_request.link);
  wl_list_remove(&window->fullscreen_request.link);
  wl_list_remove(&window->maximize_request.link);
  wl_list_remove(&window->associate.link);
  wl_list_remove(&window->dissociate.link);
  wl_list_remove(&window->destroy.link);
  wl_list_remove(&window->configure.link);
  wl_list_remove(&window->title.link);
  wl_list_remove(&window->class_name.link);
  wl_list_remove(&window->geometry.link);
  wl_list_remove(&window->link);
  if (window->server->focused == window->id) {
    window->server->focused = 0;
  }
  telar_notify(window->server);
  free(window);
}

static void xwindow_configure(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, configure);
  struct wlr_xwayland_surface_configure_event *event = data;
  // Managed windows keep the geometry selected by the workbench after mapping.
  if (!window->surface->surface || !window->surface->surface->mapped ||
      window->surface->override_redirect) {
    wlr_xwayland_surface_configure(window->surface,
                                   event->x,
                                   event->y,
                                   event->width,
                                   event->height);
  } else {
    wlr_xwayland_surface_configure(window->surface,
                                   window->surface->x,
                                   window->surface->y,
                                   window->surface->width,
                                   window->surface->height);
  }
}

static void xwindow_title(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, title);
  telar_notify(window->server);
}

static void xwindow_class(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, class_name);
  telar_notify(window->server);
}

static void xwindow_geometry(struct wl_listener *listener, void *data) {
  struct telar_xwindow *window = wl_container_of(listener, window, geometry);
  if (window->tree) {
    wlr_scene_node_set_position(&window->tree->node, window->surface->x, window->surface->y);
  }
  telar_notify(window->server);
}

static void server_new_xwayland(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, new_xwayland);
  if (wl_list_length(&server->xwindows) >= max_windows) {
    return;
  }
  struct telar_xwindow *window = calloc(1, sizeof(*window));
  if (!window) {
    return;
  }
  window->server = server;
  window->surface = data;
  window->surface->data = window;
  window->id = ++server->next_window;
  window->visible = true;
  window->placement = (struct wlr_box){window->surface->x,
                                       window->surface->y,
                                       window->surface->width,
                                       window->surface->height};
  window->activate_request.notify = xwindow_activate;
  wl_signal_add(&window->surface->events.request_activate, &window->activate_request);
  window->fullscreen_request.notify = xwindow_fullscreen;
  window->maximize_request.notify = xwindow_maximize;
  wl_signal_add(&window->surface->events.request_fullscreen, &window->fullscreen_request);
  wl_signal_add(&window->surface->events.request_maximize, &window->maximize_request);
  window->associate.notify = xwindow_associate;
  wl_signal_add(&window->surface->events.associate, &window->associate);
  window->dissociate.notify = xwindow_dissociate;
  wl_signal_add(&window->surface->events.dissociate, &window->dissociate);
  window->destroy.notify = xwindow_destroy;
  wl_signal_add(&window->surface->events.destroy, &window->destroy);
  window->configure.notify = xwindow_configure;
  wl_signal_add(&window->surface->events.request_configure, &window->configure);
  window->title.notify = xwindow_title;
  wl_signal_add(&window->surface->events.set_title, &window->title);
  window->class_name.notify = xwindow_class;
  wl_signal_add(&window->surface->events.set_class, &window->class_name);
  window->geometry.notify = xwindow_geometry;
  wl_signal_add(&window->surface->events.set_geometry, &window->geometry);
  wl_list_insert(&server->xwindows, &window->link);
}

static void xwayland_ready(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, xwayland_ready);
  wlr_xwayland_set_seat(server->xwayland, server->seat);
}

static bool matches(struct telar_toplevel *window, struct telar_target target) {
  return target.resource ? window->own && window->resource == target.resource
                         : !window->own && window->id == target.id;
}

static void place_toplevel(struct telar_toplevel *window, const struct telar_placement *placement) {
  window->space = placement->space;
  window->visible = placement->visible;
  window->focusable = placement->focusable;
  if (window->layer != placement->layer) {
    window->layer = placement->layer;
    wlr_scene_node_reparent(&window->scene_tree->node, window->server->layers[placement->layer]);
  }
  window->placement = (struct wlr_box){placement->box.x,
                                       placement->box.y,
                                       placement->box.width,
                                       placement->box.height};
  arrange_toplevel(window);
  update_visibility(window);
}

static void apply_native(struct telar_toplevel *window) {
  if (!window->own) {
    return;
  }
  struct native_placement *entry;
  wl_list_for_each(entry, &window->server->natives, link) {
    if (matches(window, entry->value.target)) {
      place_toplevel(window, &entry->value);
      return;
    }
  }
}

void telar_server_place(struct telar_server *server, const struct telar_placement *placement) {
  if (placement->box.width < 1 || placement->box.height < 1 || placement->layer > TELAR_OVERLAY) {
    return;
  }
  if (placement->target.resource) {
    struct native_placement *entry, *found = NULL;
    wl_list_for_each(entry, &server->natives, link) {
      if (entry->value.target.resource == placement->target.resource) {
        found = entry;
        break;
      }
    }
    if (!found && wl_list_length(&server->natives) < max_windows) {
      found = calloc(1, sizeof(*found));
      if (found) {
        wl_list_insert(&server->natives, &found->link);
      }
    }
    if (!found) {
      return;
    }
    found->value = *placement;
  }
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (matches(window, placement->target)) {
      place_toplevel(window, placement);
      telar_notify(server);
      return;
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (placement->target.resource || xwindow->id != placement->target.id) {
      continue;
    }
    xwindow->space = placement->space;
    xwindow->visible = placement->visible;
    xwindow->placement = (struct wlr_box){placement->box.x,
                                          placement->box.y,
                                          placement->box.width,
                                          placement->box.height};
    arrange_xwindow(xwindow);
    notify_xwindows_visibility(server);
    telar_notify(server);
    return;
  }
}

void telar_server_visible(struct telar_server *server, struct telar_target target, bool visible) {
  struct native_placement *entry;
  wl_list_for_each(entry, &server->natives, link) {
    if (target.resource == entry->value.target.resource) {
      entry->value.visible = visible;
    }
  }
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (matches(window, target)) {
      window->visible = visible;
      update_visibility(window);
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (!target.resource && xwindow->id == target.id) {
      xwindow->visible = visible;
    }
  }
  if (!target.resource) {
    notify_xwindows_visibility(server);
  }
  telar_notify(server);
}

void telar_server_focus(struct telar_server *server, struct telar_target target) {
  server->focus_request = target;
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (matches(window, target)) {
      focus_toplevel(window);
      return;
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (!target.resource && xwindow->id == target.id) {
      focus_xwindow(server, xwindow->surface->surface);
      return;
    }
  }
}

void telar_server_raise(struct telar_server *server, struct telar_target target) {
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (matches(window, target)) {
      wlr_scene_node_raise_to_top(&window->scene_tree->node);
      return;
    }
  }
}

void telar_server_close(struct telar_server *server, struct telar_target target) {
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (matches(window, target)) {
      wlr_xdg_toplevel_send_close(window->xdg_toplevel);
      return;
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (!target.resource && xwindow->id == target.id) {
      wlr_xwayland_surface_close(xwindow->surface);
      return;
    }
  }
}

void telar_update_visibility(struct telar_server *server) {
  if (!space_visible(server, server->focused_space)) {
    struct telar_output *output = telar_output_for_space(server, 0);
    server->focused_space = output ? output->space : 0;
  }
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    update_visibility(window);
  }
  notify_xwindows_visibility(server);
  telar_notify(server);
}

void telar_server_space(struct telar_server *server, uint32_t id, uint64_t space) {
  struct telar_output *target = NULL, *output;
  wl_list_for_each(output, &server->outputs, link) {
    if (output->id == id) {
      target = output;
      break;
    }
  }
  if (!target || !space) {
    return;
  }
  // Keep a workspace unique even when its previous output is disabled.
  wl_list_for_each(output, &server->outputs, link) {
    if (output != target && output->space == space) {
      output->space = target->space;
    }
  }
  target->space = space;
  server->focused_space = space;
  telar_update_visibility(server);
}

void telar_activate_surface(struct telar_server *server, struct wlr_surface *surface) {
  if (!telar_focus_allowed(server, surface) || server->locked) {
    return;
  }
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (window->xdg_toplevel->base->surface != surface || !window->mapped) {
      continue;
    }
    struct telar_output *output = telar_output_for_space(server, window->space);
    if (output && window->space) {
      telar_server_space(server, output->id, window->space);
    }
    window->visible = true;
    update_visibility(window);
    focus_toplevel(window);
    return;
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (xwindow->surface->surface != surface || !surface->mapped) {
      continue;
    }
    struct telar_output *output = telar_output_for_space(server, xwindow->space);
    if (output) {
      telar_server_space(server, output->id, xwindow->space);
    }
    xwindow->visible = true;
    xwindow_visibility(xwindow);
    focus_xwindow(server, surface);
    return;
  }
}

void telar_server_move_space(struct telar_server *server, uint64_t from, uint64_t to) {
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (window->space == from) {
      window->space = to;
      update_visibility(window);
    }
  }
  struct native_placement *entry;
  wl_list_for_each(entry, &server->natives, link) {
    if (entry->value.space == from) {
      entry->value.space = to;
    }
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    if (xwindow->space == from) {
      xwindow->space = to;
    }
  }
  notify_xwindows_visibility(server);
  telar_notify(server);
}

void telar_server_outputs(struct telar_server *server,
                          void *context,
                          void (*visit)(void *, const struct telar_output_info *)) {
  struct telar_output *output;
  wl_list_for_each(output, &server->outputs, link) {
    if (!wlr_output_layout_get(server->output_layout, output->wlr_output)) {
      continue;
    }
    struct wlr_box box;
    wlr_output_layout_get_box(server->output_layout, output->wlr_output, &box);
    struct telar_output_info info = {
        .id = output->id,
        .name = output->wlr_output->name,
        .box = {box.x, box.y, box.width, box.height},
        .usable = {output->usable.x, output->usable.y, output->usable.width, output->usable.height},
        .scale = output->wlr_output->scale,
        .space = output->space,
    };
    visit(context, &info);
  }
}

void telar_server_windows(struct telar_server *server,
                          void *context,
                          void (*visit)(void *, const struct telar_window_info *)) {
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (window->own || !window->mapped) {
      continue;
    }
    struct wlr_box geometry = window->xdg_toplevel->base->geometry;
    struct wlr_xdg_toplevel_state *state = &window->xdg_toplevel->current;
    struct telar_window_info info = {
        .id = window->id,
        .pid = window->pid,
        .application = window->xdg_toplevel->app_id,
        .title = window->xdg_toplevel->title,
        .space = window->space,
        .box = {window->scene_tree->node.x,
                window->scene_tree->node.y,
                geometry.width,
                geometry.height},
        .floating = window->xdg_toplevel->parent || (state->min_width && state->min_height &&
                                                     state->min_width == state->max_width &&
                                                     state->min_height == state->max_height),
    };
    visit(context, &info);
  }
  struct telar_xwindow *xwindow;
  wl_list_for_each(xwindow, &server->xwindows, link) {
    struct wlr_xwayland_surface *surface = xwindow->surface;
    if (!surface->surface || !surface->surface->mapped || surface->override_redirect) {
      continue;
    }
    struct telar_window_info info = {
        .id = xwindow->id,
        .pid = surface->pid,
        .application = surface->class,
        .title = surface->title,
        .space = xwindow->space,
        .box = {surface->x, surface->y, surface->width, surface->height},
        .floating = surface->parent || surface->modal,
    };
    visit(context, &info);
  }
}

uint32_t telar_server_focused(struct telar_server *server) {
  return server->focused;
}

void telar_server_surfaces(struct telar_server *server,
                           void *context,
                           void (*visit)(void *, const struct telar_surface_info *)) {
  struct telar_toplevel *window;
  wl_list_for_each(window, &server->toplevels, link) {
    if (!window->own || !window->mapped) {
      continue;
    }
    const struct wlr_box geometry = window->xdg_toplevel->base->geometry;
    const struct telar_surface_info info = {
        .resource = window->resource,
        .box = {window->scene_tree->node.x,
                window->scene_tree->node.y,
                geometry.width,
                geometry.height},
    };
    visit(context, &info);
  }
}

uint64_t telar_server_focused_space(struct telar_server *server) {
  return server->focused_space;
}

const char *telar_server_socket(struct telar_server *server) {
  return server->socket_name;
}

const char *telar_server_xdisplay(struct telar_server *server) {
  return server->xwayland ? server->xwayland->display_name : NULL;
}

void telar_server_run(struct telar_server *server) {
  wl_display_run(server->wl_display);
}

void telar_server_stop(struct telar_server *server) {
  wl_display_terminate(server->wl_display);
}

static int dispatch_commands(int fd, uint32_t mask, void *data) {
  struct telar_server *server = data;
  uint64_t value;
  while (read(fd, &value, sizeof(value)) > 0) {
  }
  server->hooks.dispatch(server->hooks.context);
  return 0;
}

static void primary_selection(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, primary_selection);
  struct wlr_seat_request_set_primary_selection_event *event = data;
  wlr_seat_set_primary_selection(server->seat, event->source, event->serial);
}

static void cursor_shape(struct wl_listener *listener, void *data) {
  struct telar_server *server = wl_container_of(listener, server, cursor_shape);
  struct wlr_cursor_shape_manager_v1_request_set_shape_event *event = data;
  if (event->seat_client == server->seat->pointer_state.focused_client &&
      wlr_seat_client_validate_event_serial(event->seat_client, event->serial)) {
    wlr_cursor_set_xcursor(server->cursor,
                           server->cursor_mgr,
                           wlr_cursor_shape_v1_name(event->shape));
  }
}

struct telar_server *telar_server_create(const struct telar_hooks *hooks, int command_fd) {
  wlr_log_init(WLR_INFO, NULL);
  struct telar_server *server = calloc(1, sizeof(*server));
  if (!server) {
    return NULL;
  }
  server->hooks = *hooks;
  wl_list_init(&server->natives);
  wl_list_init(&server->xwindows);
  wl_list_init(&server->outputs);
  wl_list_init(&server->toplevels);
  wl_list_init(&server->keyboards);
  server->wl_display = wl_display_create();
  if (!server->wl_display) {
    goto fail;
  }
  server->backend =
      wlr_backend_autocreate(wl_display_get_event_loop(server->wl_display), &server->session);
  if (server->backend == NULL) {
    wlr_log(WLR_ERROR, "failed to create wlr_backend");
    goto fail;
  }

  server->renderer = wlr_renderer_autocreate(server->backend);
  if (server->renderer == NULL) {
    wlr_log(WLR_ERROR, "failed to create wlr_renderer");
    goto fail;
  }
  if (!wlr_renderer_init_wl_display(server->renderer, server->wl_display)) {
    goto fail;
  }

  server->allocator = wlr_allocator_autocreate(server->backend, server->renderer);
  if (server->allocator == NULL) {
    wlr_log(WLR_ERROR, "failed to create wlr_allocator");
    goto fail;
  }

  server->compositor = wlr_compositor_create(server->wl_display, 6, server->renderer);
  if (!server->compositor || !wlr_subcompositor_create(server->wl_display) ||
      !wlr_data_device_manager_create(server->wl_display)) {
    goto fail;
  }

  server->output_layout = wlr_output_layout_create(server->wl_display);
  if (!server->output_layout) {
    goto fail;
  }

  wl_list_init(&server->outputs);
  server->new_output.notify = server_new_output;
  wl_signal_add(&server->backend->events.new_output, &server->new_output);

  server->scene = wlr_scene_create();
  if (!server->scene) {
    goto fail;
  }
  server->desktop_tree = wlr_scene_tree_create(&server->scene->tree);
  if (!server->desktop_tree) {
    goto fail;
  }
  for (int i = 0; i < 3; ++i) {
    server->layers[i] = wlr_scene_tree_create(server->desktop_tree);
    if (!server->layers[i]) {
      goto fail;
    }
  }
  server->fullscreen_tree = wlr_scene_tree_create(server->desktop_tree);
  server->popup_tree = wlr_scene_tree_create(server->desktop_tree);
  server->drag_tree = wlr_scene_tree_create(server->desktop_tree);
  if (!server->fullscreen_tree || !server->popup_tree || !server->drag_tree) {
    goto fail;
  }
  server->scene_layout = wlr_scene_attach_output_layout(server->scene, server->output_layout);
  if (!server->scene_layout) {
    goto fail;
  }

  wl_list_init(&server->toplevels);
  server->xdg_shell = wlr_xdg_shell_create(server->wl_display, 6);
  if (!server->xdg_shell) {
    goto fail;
  }
  server->new_xdg_toplevel.notify = server_new_xdg_toplevel;
  wl_signal_add(&server->xdg_shell->events.new_toplevel, &server->new_xdg_toplevel);
  server->new_xdg_popup.notify = server_new_xdg_popup;
  wl_signal_add(&server->xdg_shell->events.new_popup, &server->new_xdg_popup);

  server->cursor = wlr_cursor_create();
  if (!server->cursor) {
    goto fail;
  }
  wlr_cursor_attach_output_layout(server->cursor, server->output_layout);

  server->cursor_mgr = wlr_xcursor_manager_create(NULL, 24);
  if (!server->cursor_mgr) {
    goto fail;
  }

  server->cursor_mode = TELAR_CURSOR_PASSTHROUGH;
  server->cursor_motion.notify = server_cursor_motion;
  wl_signal_add(&server->cursor->events.motion, &server->cursor_motion);
  server->cursor_motion_absolute.notify = server_cursor_motion_absolute;
  wl_signal_add(&server->cursor->events.motion_absolute, &server->cursor_motion_absolute);
  server->cursor_button.notify = server_cursor_button;
  wl_signal_add(&server->cursor->events.button, &server->cursor_button);
  server->cursor_axis.notify = server_cursor_axis;
  wl_signal_add(&server->cursor->events.axis, &server->cursor_axis);
  server->cursor_frame.notify = server_cursor_frame;
  wl_signal_add(&server->cursor->events.frame, &server->cursor_frame);

  wl_list_init(&server->keyboards);
  server->new_input.notify = server_new_input;
  wl_signal_add(&server->backend->events.new_input, &server->new_input);
  server->seat = wlr_seat_create(server->wl_display, "seat0");
  if (!server->seat) {
    goto fail;
  }
  server->request_cursor.notify = seat_request_cursor;
  wl_signal_add(&server->seat->events.request_set_cursor, &server->request_cursor);
  server->pointer_focus_change.notify = seat_pointer_focus_change;
  wl_signal_add(&server->seat->pointer_state.events.focus_change, &server->pointer_focus_change);
  server->request_set_selection.notify = seat_request_set_selection;
  wl_signal_add(&server->seat->events.request_set_selection, &server->request_set_selection);

  if (!telar_shell_init(server) || !telar_input_method_init(server) ||
      !telar_pointer_init(server) || !telar_lock_init(server)) {
    goto fail;
  }
  wlr_viewporter_create(server->wl_display);
  wlr_fractional_scale_manager_v1_create(server->wl_display, 1);
  wlr_xdg_output_manager_v1_create(server->wl_display, server->output_layout);
  wlr_primary_selection_v1_device_manager_create(server->wl_display);
  wlr_screencopy_manager_v1_create(server->wl_display);
  wlr_data_control_manager_v1_create(server->wl_display);
  server->primary_selection.notify = primary_selection;
  wl_signal_add(&server->seat->events.request_set_primary_selection, &server->primary_selection);
  struct wlr_cursor_shape_manager_v1 *shapes =
      wlr_cursor_shape_manager_v1_create(server->wl_display, 1);
  if (!shapes) {
    goto fail;
  }
  server->cursor_shape.notify = cursor_shape;
  wl_signal_add(&shapes->events.request_set_shape, &server->cursor_shape);
  server->xwayland = wlr_xwayland_create(server->wl_display, server->compositor, true);
  if (!server->xwayland) {
    goto fail;
  }
  server->new_xwayland.notify = server_new_xwayland;
  wl_signal_add(&server->xwayland->events.new_surface, &server->new_xwayland);
  server->xwayland_ready.notify = xwayland_ready;
  wl_signal_add(&server->xwayland->events.ready, &server->xwayland_ready);
  server->commands = wl_event_loop_add_fd(wl_display_get_event_loop(server->wl_display),
                                          command_fd,
                                          WL_EVENT_READABLE,
                                          dispatch_commands,
                                          server);
  if (!server->commands) {
    goto fail;
  }
  server->socket_name = wl_display_add_socket_auto(server->wl_display);
  if (!server->socket_name) {
    goto fail;
  }

  if (!wlr_backend_start(server->backend)) {
    goto fail;
  }

  return server;
fail:
  telar_server_destroy(server);
  return NULL;
}

void telar_server_destroy(struct telar_server *server) {
  if (!server) {
    return;
  }
  server->destroying = true;
  if (server->changed_idle) {
    wl_event_source_remove(server->changed_idle);
  }
  if (server->commands) {
    wl_event_source_remove(server->commands);
  }
  if (server->new_xwayland.link.next) {
    wl_list_remove(&server->new_xwayland.link);
    server->new_xwayland.link.next = NULL;
  }
  if (server->xwayland_ready.link.next) {
    wl_list_remove(&server->xwayland_ready.link);
    server->xwayland_ready.link.next = NULL;
  }
  if (server->xwayland) {
    wlr_xwayland_destroy(server->xwayland);
  }
  if (server->wl_display) {
    wl_display_destroy_clients(server->wl_display);
  }
  telar_lock_finish(server);
  telar_pointer_finish(server);
  telar_input_method_finish(server);
  telar_shell_finish(server);
  if (server->new_xdg_toplevel.link.next) {
    wl_list_remove(&server->new_xdg_toplevel.link);
  }
  if (server->new_xdg_popup.link.next) {
    wl_list_remove(&server->new_xdg_popup.link);
  }
  if (server->cursor_motion.link.next) {
    wl_list_remove(&server->cursor_motion.link);
  }
  if (server->cursor_motion_absolute.link.next) {
    wl_list_remove(&server->cursor_motion_absolute.link);
  }
  if (server->cursor_button.link.next) {
    wl_list_remove(&server->cursor_button.link);
  }
  if (server->cursor_axis.link.next) {
    wl_list_remove(&server->cursor_axis.link);
  }
  if (server->cursor_frame.link.next) {
    wl_list_remove(&server->cursor_frame.link);
  }
  if (server->new_input.link.next) {
    wl_list_remove(&server->new_input.link);
  }
  if (server->request_cursor.link.next) {
    wl_list_remove(&server->request_cursor.link);
  }
  if (server->pointer_focus_change.link.next) {
    wl_list_remove(&server->pointer_focus_change.link);
  }
  if (server->request_set_selection.link.next) {
    wl_list_remove(&server->request_set_selection.link);
  }
  if (server->new_output.link.next) {
    wl_list_remove(&server->new_output.link);
  }
  if (server->primary_selection.link.next) {
    wl_list_remove(&server->primary_selection.link);
  }
  if (server->cursor_shape.link.next) {
    wl_list_remove(&server->cursor_shape.link);
  }
  if (server->backend) {
    wlr_backend_destroy(server->backend);
  }
  if (server->scene) {
    wlr_scene_node_destroy(&server->scene->tree.node);
  }
  if (server->cursor_mgr) {
    wlr_xcursor_manager_destroy(server->cursor_mgr);
  }
  if (server->cursor) {
    wlr_cursor_destroy(server->cursor);
  }
  if (server->allocator) {
    wlr_allocator_destroy(server->allocator);
  }
  if (server->renderer) {
    wlr_renderer_destroy(server->renderer);
  }
  if (server->wl_display) {
    wl_display_destroy(server->wl_display);
  }
  struct native_placement *entry, *temporary;
  wl_list_for_each_safe(entry, temporary, &server->natives, link) {
    wl_list_remove(&entry->link);
    free(entry);
  }
  free(server);
}
