#include "compositor_internal.h"
#include <wlr/types/wlr_session_lock_v1.h>

struct lock_output {
  struct wl_list link;
  struct telar_lock *lock;
  struct wlr_output *output;
  struct wlr_scene_rect *blank;
  struct wl_listener present, destroy;
  uint32_t blank_sequence;
  bool pending;
};

struct lock_surface {
  struct telar_lock *lock;
  struct wlr_session_lock_surface_v1 *surface;
  struct wlr_scene_tree *tree;
  struct wl_listener map, destroy;
};

struct telar_lock {
  struct telar_server *server;
  struct wlr_scene_tree *tree;
  struct wlr_scene_tree *surfaces;
  struct wlr_session_lock_v1 *client;
  struct wl_list outputs;
  struct wl_listener request, new_surface, unlock, destroy;
  bool acknowledged;
};

// The protocol's locked event is a security boundary: wait for every enabled
// output to present a frame with the desktop hidden before acknowledging it.
static void acknowledge(struct telar_lock *lock) {
  if (!lock->client || lock->acknowledged) {
    return;
  }

  struct lock_output *output;
  wl_list_for_each(output, &lock->outputs, link) {
    if (output->output->enabled && output->pending) {
      return;
    }
  }

  struct telar_output *monitor;
  wl_list_for_each(monitor, &lock->server->outputs, link) {
    bool covered = false;
    wl_list_for_each(output, &lock->outputs, link) {
      covered |= output->output == monitor->wlr_output;
    }
    if (monitor->wlr_output->enabled && !covered) {
      return;
    }
  }

  lock->acknowledged = true;
  wlr_session_lock_v1_send_locked(lock->client);
}

static void output_present(struct wl_listener *listener, void *data) {
  struct lock_output *output = wl_container_of(listener, output, present);
  struct wlr_output_event_present *event = data;
  if (event->presented && (int32_t)(event->commit_seq - output->blank_sequence) >= 0) {
    output->pending = false;
    acknowledge(output->lock);
  }
}

static void output_destroy(struct wl_listener *listener, void *data) {
  struct lock_output *output = wl_container_of(listener, output, destroy);
  struct telar_lock *lock = output->lock;
  wl_list_remove(&output->present.link);
  wl_list_remove(&output->destroy.link);
  wl_list_remove(&output->link);
  wlr_scene_node_destroy(&output->blank->node);
  free(output);
  acknowledge(lock);
}

void telar_lock_outputs(struct telar_server *server) {
  struct telar_lock *lock = server->lock;
  if (!lock) {
    return;
  }

  struct telar_output *monitor;
  wl_list_for_each(monitor, &server->outputs, link) {
    struct lock_output *output, *found = NULL;
    wl_list_for_each(output, &lock->outputs, link) {
      if (output->output == monitor->wlr_output) {
        found = output;
        break;
      }
    }

    if (!found) {
      found = calloc(1, sizeof(*found));
      const float black[] = {0, 0, 0, 1};
      if (!found || !(found->blank = wlr_scene_rect_create(lock->tree, 0, 0, black))) {
        free(found);
        // Never expose an output we cannot cover, including after locker death.
        if (monitor->wlr_output->enabled) {
          struct wlr_output_state state;
          wlr_output_state_init(&state);
          wlr_output_state_set_enabled(&state, false);
          wlr_output_commit_state(monitor->wlr_output, &state);
          wlr_output_state_finish(&state);
        }
        continue;
      }

      found->lock = lock;
      found->output = monitor->wlr_output;
      found->pending = server->locked;
      found->blank_sequence = found->output->commit_seq + 1;
      found->present.notify = output_present;
      wl_signal_add(&found->output->events.present, &found->present);
      found->destroy.notify = output_destroy;
      wl_signal_add(&found->output->events.destroy, &found->destroy);
      wl_list_insert(&lock->outputs, &found->link);
      wlr_scene_node_lower_to_bottom(&found->blank->node);
    }

    struct wlr_box box;
    wlr_output_layout_get_box(server->output_layout, monitor->wlr_output, &box);
    wlr_scene_node_set_position(&found->blank->node, box.x, box.y);
    wlr_scene_rect_set_size(found->blank, box.width, box.height);
  }

  if (lock->client) {
    struct wlr_session_lock_surface_v1 *surface;
    wl_list_for_each(surface, &lock->client->surfaces, link) {
      struct lock_surface *view = surface->data;
      struct wlr_box box;
      wlr_output_layout_get_box(server->output_layout, surface->output, &box);
      if (view) {
        wlr_scene_node_set_position(&view->tree->node, box.x, box.y);
      }
      if (box.width > 0 && box.height > 0) {
        wlr_session_lock_surface_v1_configure(surface, box.width, box.height);
      }
    }
  }
  acknowledge(lock);
}

static void surface_map(struct wl_listener *listener, void *data) {
  struct lock_surface *view = wl_container_of(listener, view, map);
  telar_focus_surface(view->lock->server, view->surface->surface);
}

static void surface_destroy(struct wl_listener *listener, void *data) {
  struct lock_surface *view = wl_container_of(listener, view, destroy);
  wl_list_remove(&view->map.link);
  wl_list_remove(&view->destroy.link);
  wlr_scene_node_destroy(&view->tree->node);
  free(view);
}

static void new_surface(struct wl_listener *listener, void *data) {
  struct telar_lock *lock = wl_container_of(listener, lock, new_surface);
  struct wlr_session_lock_surface_v1 *surface = data;
  struct lock_surface *view = calloc(1, sizeof(*view));
  if (!view) {
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }

  view->lock = lock;
  view->surface = surface;
  view->tree = wlr_scene_tree_create(lock->surfaces);
  if (!view->tree || !wlr_scene_subsurface_tree_create(view->tree, surface->surface)) {
    if (view->tree) {
      wlr_scene_node_destroy(&view->tree->node);
    }
    free(view);
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }

  surface->data = view;
  view->map.notify = surface_map;
  wl_signal_add(&surface->surface->events.map, &view->map);
  view->destroy.notify = surface_destroy;
  wl_signal_add(&surface->events.destroy, &view->destroy);
  telar_lock_outputs(lock->server);
}

static void client_destroy(struct wl_listener *listener, void *data) {
  struct telar_lock *lock = wl_container_of(listener, lock, destroy);
  wl_list_remove(&lock->new_surface.link);
  wl_list_remove(&lock->unlock.link);
  wl_list_remove(&lock->destroy.link);
  lock->client = NULL;
  // A disconnected or crashed locker leaves the scene black and input blocked.
  // A replacement locker can authenticate the user and explicitly unlock it.
}

static void unlock(struct wl_listener *listener, void *data) {
  struct telar_lock *lock = wl_container_of(listener, lock, unlock);
  struct telar_server *server = lock->server;
  if (!lock->acknowledged) {
    return;
  }

  server->locked = false;
  wlr_scene_node_set_enabled(&lock->tree->node, false);
  wlr_scene_node_set_enabled(&server->desktop_tree->node, true);
  wlr_seat_keyboard_clear_focus(server->seat);
  telar_restore_focus(server);
  telar_shell_visibility(server);
}

static void request(struct wl_listener *listener, void *data) {
  struct telar_lock *lock = wl_container_of(listener, lock, request);
  struct wlr_session_lock_v1 *client = data;
  if (lock->client) {
    wlr_session_lock_v1_destroy(client);
    return;
  }

  struct telar_server *server = lock->server;
  lock->client = client;
  lock->acknowledged = false;
  server->locked = true;
  server->cursor_mode = TELAR_CURSOR_PASSTHROUGH;
  server->grabbed_toplevel = NULL;
  server->hooks.cancel_shortcuts(server->hooks.context);
  if (server->seat->drag && server->seat->drag->source) {
    wlr_data_source_destroy(server->seat->drag->source);
  }
  wlr_seat_pointer_end_grab(server->seat);
  wlr_seat_keyboard_end_grab(server->seat);
  wlr_seat_pointer_clear_focus(server->seat);
  wlr_seat_keyboard_clear_focus(server->seat);
  wlr_scene_node_set_enabled(&server->desktop_tree->node, false);
  wlr_scene_node_set_enabled(&lock->tree->node, true);
  wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");

  lock->new_surface.notify = new_surface;
  wl_signal_add(&client->events.new_surface, &lock->new_surface);
  lock->unlock.notify = unlock;
  wl_signal_add(&client->events.unlock, &lock->unlock);
  lock->destroy.notify = client_destroy;
  wl_signal_add(&client->events.destroy, &lock->destroy);

  struct lock_output *output;
  wl_list_for_each(output, &lock->outputs, link) {
    output->pending = output->output->enabled;
    output->blank_sequence = output->output->commit_seq + 1;
    wlr_output_schedule_frame(output->output);
  }
  telar_shell_visibility(server);
  acknowledge(lock);
}

bool telar_lock_init(struct telar_server *server) {
  struct wlr_session_lock_manager_v1 *manager =
      wlr_session_lock_manager_v1_create(server->wl_display);
  struct telar_lock *lock = calloc(1, sizeof(*lock));
  if (!manager || !lock) {
    free(lock);
    return false;
  }

  lock->server = server;
  wl_list_init(&lock->outputs);
  lock->tree = wlr_scene_tree_create(&server->scene->tree);
  lock->surfaces = lock->tree ? wlr_scene_tree_create(lock->tree) : NULL;
  if (!lock->surfaces) {
    if (lock->tree) {
      wlr_scene_node_destroy(&lock->tree->node);
    }
    free(lock);
    return false;
  }

  wlr_scene_node_set_enabled(&lock->tree->node, false);
  lock->request.notify = request;
  wl_signal_add(&manager->events.new_lock, &lock->request);
  server->lock = lock;
  return true;
}

void telar_lock_finish(struct telar_server *server) {
  struct telar_lock *lock = server->lock;
  if (!lock) {
    return;
  }

  if (lock->client) {
    client_destroy(&lock->destroy, NULL);
  }
  struct lock_output *output, *temporary;
  wl_list_for_each_safe(output, temporary, &lock->outputs, link) {
    output_destroy(&output->destroy, NULL);
  }
  wl_list_remove(&lock->request.link);
  wlr_scene_node_destroy(&lock->tree->node);
  free(lock);
  server->lock = NULL;
}
