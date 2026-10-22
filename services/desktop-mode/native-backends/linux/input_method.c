#include "compositor_internal.h"
#include <wlr/types/wlr_input_method_v2.h>
#include <wlr/types/wlr_text_input_v3.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>

struct text_input {
  struct wl_list link;
  struct telar_input_method *relay;
  struct wlr_text_input_v3 *input;
  struct wl_listener enable, commit, disable, destroy;
};

struct input_popup {
  struct wl_list link;
  struct telar_input_method *relay;
  struct wlr_input_popup_surface_v2 *surface;
  struct wlr_scene_tree *tree;
  struct wl_listener commit, destroy;
};

struct telar_input_method {
  struct telar_server *server;
  struct wlr_input_method_v2 *method;
  struct text_input *active;
  struct wl_list inputs, popups;
  struct wl_listener new_input, new_method, focus, new_keyboard;
  struct wl_listener commit, destroy, popup, grab;
};

static void update_popups(struct telar_input_method *relay) {
  struct text_input *active = relay->active;
  struct wlr_surface *surface = active ? active->input->focused_surface : NULL;
  struct wlr_scene_tree *parent = surface ? telar_surface_tree(relay->server, surface) : NULL;
  int x = 0, y = 0;
  bool visible = parent && !relay->server->locked && wlr_scene_node_coords(&parent->node, &x, &y);
  struct wlr_box cursor = {0};
  if (active) {
    cursor = active->input->current.cursor_rectangle;
  }
  struct wlr_xdg_surface *xdg = surface ? wlr_xdg_surface_try_from_wlr_surface(surface) : NULL;
  if (xdg) {
    x -= xdg->geometry.x;
    y -= xdg->geometry.y;
  }

  struct input_popup *popup;
  wl_list_for_each(popup, &relay->popups, link) {
    wlr_scene_node_set_enabled(&popup->tree->node, visible);
    if (!visible) {
      continue;
    }

    int px = x + cursor.x, py = y + cursor.y + cursor.height;
    struct wlr_output *output = wlr_output_layout_output_at(relay->server->output_layout, px, py);
    if (!output) {
      struct telar_output *fallback =
          telar_output_for_space(relay->server, relay->server->focused_space);
      output = fallback ? fallback->wlr_output : NULL;
    }
    if (output) {
      struct wlr_box box;
      wlr_output_layout_get_box(relay->server->output_layout, output, &box);
      int width = popup->surface->surface->current.width;
      int height = popup->surface->surface->current.height;
      if (px + width > box.x + box.width) {
        px = box.x + box.width - width;
      }
      if (py + height > box.y + box.height) {
        py = y + cursor.y - height;
      }
      if (px < box.x) {
        px = box.x;
      }
      if (py < box.y) {
        py = box.y;
      }
    }
    wlr_scene_node_set_position(&popup->tree->node, px, py);
    struct wlr_box relative = {x + cursor.x - px, y + cursor.y - py, cursor.width, cursor.height};
    wlr_input_popup_surface_v2_send_text_input_rectangle(popup->surface, &relative);
  }
}

static void send_state(struct telar_input_method *relay) {
  if (!relay->method || !relay->active) {
    return;
  }

  struct wlr_text_input_v3 *input = relay->active->input;
  struct wlr_text_input_v3_state *state = &input->current;
  if (input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) {
    wlr_input_method_v2_send_surrounding_text(relay->method,
                                              state->surrounding.text ? state->surrounding.text
                                                                      : "",
                                              state->surrounding.cursor,
                                              state->surrounding.anchor);
  }
  wlr_input_method_v2_send_text_change_cause(relay->method, state->text_change_cause);
  if (input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
    wlr_input_method_v2_send_content_type(relay->method,
                                          state->content_type.hint,
                                          state->content_type.purpose);
  }
  wlr_input_method_v2_send_done(relay->method);
  update_popups(relay);
}

static void deactivate(struct telar_input_method *relay) {
  if (relay->active && relay->method) {
    wlr_input_method_v2_send_deactivate(relay->method);
    wlr_input_method_v2_send_done(relay->method);
  }
  relay->active = NULL;
  update_popups(relay);
}

static void enable(struct wl_listener *listener, void *data) {
  struct text_input *input = wl_container_of(listener, input, enable);
  struct telar_input_method *relay = input->relay;
  if (!input->input->focused_surface || relay->server->locked) {
    return;
  }

  if (relay->active && relay->active != input) {
    deactivate(relay);
  }
  relay->active = input;
  if (relay->method) {
    wlr_input_method_v2_send_activate(relay->method);
    send_state(relay);
  }
}

static void input_commit(struct wl_listener *listener, void *data) {
  struct text_input *input = wl_container_of(listener, input, commit);
  if (input->relay->active == input) {
    send_state(input->relay);
  }
}

static void disable(struct wl_listener *listener, void *data) {
  struct text_input *input = wl_container_of(listener, input, disable);
  if (input->relay->active == input) {
    deactivate(input->relay);
  }
}

static void input_destroy(struct wl_listener *listener, void *data) {
  struct text_input *input = wl_container_of(listener, input, destroy);
  disable(&input->disable, NULL);
  wl_list_remove(&input->enable.link);
  wl_list_remove(&input->commit.link);
  wl_list_remove(&input->disable.link);
  wl_list_remove(&input->destroy.link);
  wl_list_remove(&input->link);
  free(input);
}

void telar_input_method_update(struct telar_server *server) {
  struct telar_input_method *relay = server->input_method;
  if (!relay) {
    return;
  }

  struct wlr_surface *surface =
      server->locked ? NULL : server->seat->keyboard_state.focused_surface;
  struct text_input *input;
  wl_list_for_each(input, &relay->inputs, link) {
    if (input->input->focused_surface && input->input->focused_surface != surface) {
      disable(&input->disable, NULL);
      wlr_text_input_v3_send_leave(input->input);
    }
    if (surface && !input->input->focused_surface &&
        wl_resource_get_client(input->input->resource) ==
            wl_resource_get_client(surface->resource)) {
      wlr_text_input_v3_send_enter(input->input, surface);
    }
  }
  update_popups(relay);
}

static void focus(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, focus);
  telar_input_method_update(relay->server);
}

static void new_input(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, new_input);
  struct wlr_text_input_v3 *source = data;
  if (source->seat != relay->server->seat) {
    return;
  }
  struct text_input *input = calloc(1, sizeof(*input));
  if (!input) {
    wl_client_post_no_memory(wl_resource_get_client(source->resource));
    return;
  }
  input->relay = relay;
  input->input = source;
  input->enable.notify = enable;
  input->commit.notify = input_commit;
  input->disable.notify = disable;
  input->destroy.notify = input_destroy;
  wl_signal_add(&source->events.enable, &input->enable);
  wl_signal_add(&source->events.commit, &input->commit);
  wl_signal_add(&source->events.disable, &input->disable);
  wl_signal_add(&source->events.destroy, &input->destroy);
  wl_list_insert(&relay->inputs, &input->link);
  telar_input_method_update(relay->server);
}

static void method_commit(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, commit);
  if (!relay->active || relay->server->locked || !relay->active->input->focused_surface) {
    return;
  }

  struct wlr_text_input_v3 *input = relay->active->input;
  struct wlr_input_method_v2_state *state = &relay->method->current;
  wlr_text_input_v3_send_preedit_string(input,
                                        state->preedit.text ? state->preedit.text : "",
                                        state->preedit.cursor_begin,
                                        state->preedit.cursor_end);
  if (state->commit_text) {
    wlr_text_input_v3_send_commit_string(input, state->commit_text);
  }
  if (state->delete.before_length || state->delete.after_length) {
    wlr_text_input_v3_send_delete_surrounding_text(input,
                                                   state->delete.before_length,
                                                   state->delete.after_length);
  }
  wlr_text_input_v3_send_done(input);
}

static void popup_commit(struct wl_listener *listener, void *data) {
  struct input_popup *popup = wl_container_of(listener, popup, commit);
  update_popups(popup->relay);
}

static void popup_destroy(struct wl_listener *listener, void *data) {
  struct input_popup *popup = wl_container_of(listener, popup, destroy);
  wl_list_remove(&popup->commit.link);
  wl_list_remove(&popup->destroy.link);
  wl_list_remove(&popup->link);
  wlr_scene_node_destroy(&popup->tree->node);
  free(popup);
}

static void new_popup(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, popup);
  struct wlr_input_popup_surface_v2 *surface = data;
  struct input_popup *popup = calloc(1, sizeof(*popup));
  if (!popup) {
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }
  popup->tree = wlr_scene_tree_create(relay->server->popup_tree);
  if (!popup->tree || !wlr_scene_subsurface_tree_create(popup->tree, surface->surface)) {
    if (popup->tree) {
      wlr_scene_node_destroy(&popup->tree->node);
    }
    free(popup);
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }
  popup->relay = relay;
  popup->surface = surface;
  popup->commit.notify = popup_commit;
  popup->destroy.notify = popup_destroy;
  wl_signal_add(&surface->surface->events.commit, &popup->commit);
  wl_signal_add(&surface->events.destroy, &popup->destroy);
  wl_list_insert(&relay->popups, &popup->link);
  update_popups(relay);
}

static void grab(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, grab);
  struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(relay->server->seat);
  if (keyboard && !wlr_input_device_get_virtual_keyboard(&keyboard->base)) {
    wlr_input_method_keyboard_grab_v2_set_keyboard(data, keyboard);
  }
}

static void method_destroy(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, destroy);
  wl_list_remove(&relay->commit.link);
  wl_list_remove(&relay->destroy.link);
  wl_list_remove(&relay->popup.link);
  wl_list_remove(&relay->grab.link);
  relay->method = NULL;
  // Keep the enabled text input so a restarted input method can resume it.
}

static void new_method(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, new_method);
  struct wlr_input_method_v2 *method = data;
  if (relay->method || method->seat != relay->server->seat) {
    wlr_input_method_v2_send_unavailable(method);
    return;
  }
  relay->method = method;
  relay->commit.notify = method_commit;
  relay->destroy.notify = method_destroy;
  relay->popup.notify = new_popup;
  relay->grab.notify = grab;
  wl_signal_add(&method->events.commit, &relay->commit);
  wl_signal_add(&method->events.destroy, &relay->destroy);
  wl_signal_add(&method->events.new_popup_surface, &relay->popup);
  wl_signal_add(&method->events.grab_keyboard, &relay->grab);
  if (relay->active) {
    wlr_input_method_v2_send_activate(method);
    send_state(relay);
  }
}

static void new_keyboard(struct wl_listener *listener, void *data) {
  struct telar_input_method *relay = wl_container_of(listener, relay, new_keyboard);
  struct wlr_virtual_keyboard_v1 *keyboard = data;
  if (keyboard->seat == relay->server->seat) {
    telar_new_keyboard(relay->server, &keyboard->keyboard.base);
  }
}

static struct wlr_input_method_keyboard_grab_v2 *keyboard_grab(struct telar_server *server,
                                                               struct wlr_keyboard *keyboard) {
  struct telar_input_method *relay = server->input_method;
  if (!relay || !relay->method || server->locked) {
    return NULL;
  }
  struct wlr_virtual_keyboard_v1 *virtual = wlr_input_device_get_virtual_keyboard(&keyboard->base);
  if (virtual && wl_resource_get_client(virtual->resource) ==
                     wl_resource_get_client(relay->method->resource)) {
    return NULL;
  }
  return relay->method->keyboard_grab;
}

bool telar_input_method_key(struct telar_server *server,
                            struct wlr_keyboard *keyboard,
                            struct wlr_keyboard_key_event *event) {
  struct wlr_input_method_keyboard_grab_v2 *grab = keyboard_grab(server, keyboard);
  if (!grab) {
    return false;
  }
  wlr_input_method_keyboard_grab_v2_set_keyboard(grab, keyboard);
  wlr_input_method_keyboard_grab_v2_send_key(grab, event->time_msec, event->keycode, event->state);
  return true;
}

bool telar_input_method_modifiers(struct telar_server *server, struct wlr_keyboard *keyboard) {
  struct wlr_input_method_keyboard_grab_v2 *grab = keyboard_grab(server, keyboard);
  if (!grab) {
    return false;
  }
  wlr_input_method_keyboard_grab_v2_set_keyboard(grab, keyboard);
  wlr_input_method_keyboard_grab_v2_send_modifiers(grab, &keyboard->modifiers);
  return true;
}

bool telar_input_method_init(struct telar_server *server) {
  struct wlr_text_input_manager_v3 *inputs = wlr_text_input_manager_v3_create(server->wl_display);
  struct wlr_input_method_manager_v2 *methods =
      wlr_input_method_manager_v2_create(server->wl_display);
  struct wlr_virtual_keyboard_manager_v1 *keyboards =
      wlr_virtual_keyboard_manager_v1_create(server->wl_display);
  struct telar_input_method *relay = calloc(1, sizeof(*relay));
  if (!inputs || !methods || !keyboards || !relay) {
    free(relay);
    return false;
  }
  relay->server = server;
  wl_list_init(&relay->inputs);
  wl_list_init(&relay->popups);
  relay->new_input.notify = new_input;
  relay->new_method.notify = new_method;
  relay->new_keyboard.notify = new_keyboard;
  relay->focus.notify = focus;
  wl_signal_add(&inputs->events.new_text_input, &relay->new_input);
  wl_signal_add(&methods->events.new_input_method, &relay->new_method);
  wl_signal_add(&keyboards->events.new_virtual_keyboard, &relay->new_keyboard);
  wl_signal_add(&server->seat->keyboard_state.events.focus_change, &relay->focus);
  server->input_method = relay;
  return true;
}

void telar_input_method_finish(struct telar_server *server) {
  struct telar_input_method *relay = server->input_method;
  if (!relay) {
    return;
  }
  wl_list_remove(&relay->new_input.link);
  wl_list_remove(&relay->new_method.link);
  wl_list_remove(&relay->new_keyboard.link);
  wl_list_remove(&relay->focus.link);
  free(relay);
  server->input_method = NULL;
}
