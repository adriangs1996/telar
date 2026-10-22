#include "compositor_internal.h"
#include <math.h>
#include <wlr/types/wlr_xdg_foreign_registry.h>
#include <wlr/types/wlr_xdg_foreign_v1.h>
#include <wlr/types/wlr_xdg_foreign_v2.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_output_power_management_v1.h>
#include <wlr/types/wlr_idle_notify_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_ext_image_capture_source_v1.h>
#include <wlr/types/wlr_ext_image_copy_capture_v1.h>

struct layer_view {
  struct wl_list link;
  struct telar_shell *shell;
  struct wlr_layer_surface_v1 *surface;
  struct wlr_scene_layer_surface_v1 *scene;
  struct wl_listener commit, map, unmap, destroy, popup, output_destroy;
};

struct inhibitor {
  struct wl_list link;
  struct telar_shell *shell;
  struct wlr_idle_inhibitor_v1 *source;
  struct wl_listener destroy;
};

struct decoration {
  struct wlr_xdg_toplevel_decoration_v1 *source;
  struct wl_listener request, commit, destroy;
};

struct telar_shell {
  struct telar_server *server;
  struct wlr_scene_tree *layers[4];
  struct wl_list views, inhibitors;
  struct wlr_output_manager_v1 *outputs;
  struct wl_listener new_layer, apply, test, layout, power;
  struct wl_listener request_drag, start_drag, new_inhibitor, activation, decoration;
  bool arranging;
};

static struct layer_view *exclusive(struct telar_shell *shell) {
  struct layer_view *view, *found = NULL;
  wl_list_for_each(view, &shell->views, link) {
    struct wlr_layer_surface_v1_state *state = &view->surface->current;
    if (view->surface->surface->mapped &&
        wlr_output_layout_get(shell->server->output_layout, view->surface->output) &&
        state->keyboard_interactive == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE &&
        state->layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP &&
        (!found || state->layer > found->surface->current.layer)) {
      found = view;
    }
  }
  return found;
}

bool telar_shell_exclusive(struct telar_server *server, struct wlr_surface *surface) {
  if (!server->shell) {
    return false;
  }
  struct layer_view *view = exclusive(server->shell);
  if (!view) {
    return false;
  }
  struct wlr_scene_tree *tree = telar_surface_tree(server, surface);
  while (tree) {
    if (tree == view->scene->tree) {
      return false;
    }
    tree = tree->node.parent;
  }
  return true;
}

bool telar_shell_focus(struct telar_server *server, struct wlr_surface *surface) {
  if (!surface || server->locked) {
    return false;
  }
  struct wlr_layer_surface_v1 *layer =
      wlr_layer_surface_v1_try_from_wlr_surface(wlr_surface_get_root_surface(surface));
  if (!layer) {
    return false;
  }
  if (layer->current.keyboard_interactive != ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) {
    telar_focus_surface(server, surface);
  }
  return true;
}

void telar_shell_visibility(struct telar_server *server) {
  struct telar_shell *shell = server->shell;
  if (!shell) {
    return;
  }
  bool inhibited = false;
  struct inhibitor *inhibitor;
  wl_list_for_each(inhibitor, &shell->inhibitors, link) {
    struct wlr_scene_tree *tree = telar_surface_tree(server, inhibitor->source->surface);
    int x, y;
    if (!server->locked && tree && inhibitor->source->surface->mapped &&
        wlr_scene_node_coords(&tree->node, &x, &y)) {
      inhibited = true;
      break;
    }
  }
  wlr_idle_notifier_v1_set_inhibited(server->idle, inhibited);
  telar_input_method_update(server);
}

static void arrange(struct telar_shell *shell) {
  if (shell->arranging || shell->server->destroying) {
    return;
  }
  shell->arranging = true;
  struct telar_output *output;
  wl_list_for_each(output, &shell->server->outputs, link) {
    bool enabled = wlr_output_layout_get(shell->server->output_layout, output->wlr_output) != NULL;
    struct layer_view *view;
    wl_list_for_each(view, &shell->views, link) {
      if (view->surface->output == output->wlr_output) {
        wlr_scene_node_set_enabled(&view->scene->tree->node,
                                   enabled && view->surface->surface->mapped);
      }
    }
    if (!enabled) {
      continue;
    }
    struct wlr_box full;
    wlr_output_layout_get_box(shell->server->output_layout, output->wlr_output, &full);
    struct wlr_box usable = full;
    // Reserve mapped exclusive panels before placing non-exclusive surfaces.
    for (int pass = 0; pass < 2; ++pass) {
      for (int layer = ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY; layer >= 0; --layer) {
        struct layer_view *view;
        wl_list_for_each(view, &shell->views, link) {
          struct wlr_layer_surface_v1 *surface = view->surface;
          if (surface->output != output->wlr_output || !surface->initialized ||
              surface->current.layer != (unsigned)layer ||
              (surface->current.exclusive_zone > 0) != (pass == 0)) {
            continue;
          }
          struct wlr_box configured = usable;
          wlr_scene_layer_surface_v1_configure(view->scene, &full, &configured);
          if (surface->surface->mapped) {
            usable = configured;
          }
        }
      }
    }
    if (!wlr_box_equal(&output->usable, &usable)) {
      output->workarea = usable;
    }
    output->usable = usable;
  }
  struct layer_view *focused = exclusive(shell);
  if (focused && !shell->server->locked) {
    telar_focus_surface(shell->server, focused->surface->surface);
  }
  shell->arranging = false;
  telar_shell_visibility(shell->server);
  telar_arrange_windows(shell->server);
  telar_notify(shell->server);
}

static void layer_commit(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, commit);
  if (view->surface->initial_commit || view->surface->current.committed) {
    wlr_scene_node_reparent(&view->scene->tree->node,
                            view->shell->layers[view->surface->current.layer]);
    arrange(view->shell);
  }
}

static void layer_map(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, map);
  arrange(view->shell);
}

static void layer_unmap(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, unmap);
  struct telar_server *server = view->shell->server;
  if (server->seat->keyboard_state.focused_surface == view->surface->surface) {
    wlr_seat_keyboard_clear_focus(server->seat);
  }
  arrange(view->shell);
  telar_restore_focus(server);
}

static void layer_destroy(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, destroy);
  struct telar_shell *shell = view->shell;
  wl_list_remove(&view->commit.link);
  wl_list_remove(&view->map.link);
  wl_list_remove(&view->unmap.link);
  wl_list_remove(&view->destroy.link);
  wl_list_remove(&view->popup.link);
  wl_list_remove(&view->output_destroy.link);
  wl_list_remove(&view->link);
  free(view);
  arrange(shell);
}

static void layer_popup(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, popup);
  telar_create_popup(view->shell->server, data, view->scene->tree);
}

static void layer_output_destroy(struct wl_listener *listener, void *data) {
  struct layer_view *view = wl_container_of(listener, view, output_destroy);
  wlr_layer_surface_v1_destroy(view->surface);
}

static void new_layer(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, new_layer);
  struct wlr_layer_surface_v1 *surface = data;
  if (!surface->output) {
    struct telar_output *output =
        telar_output_for_space(shell->server, shell->server->focused_space);
    surface->output = output ? output->wlr_output : NULL;
  }
  if (!surface->output) {
    wlr_layer_surface_v1_destroy(surface);
    return;
  }
  struct layer_view *view = calloc(1, sizeof(*view));
  if (!view) {
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }
  view->shell = shell;
  view->surface = surface;
  view->scene = wlr_scene_layer_surface_v1_create(shell->layers[surface->pending.layer], surface);
  if (!view->scene) {
    free(view);
    wl_client_post_no_memory(wl_resource_get_client(surface->resource));
    return;
  }
  surface->data = view->scene->tree;
  view->commit.notify = layer_commit;
  view->map.notify = layer_map;
  view->unmap.notify = layer_unmap;
  view->destroy.notify = layer_destroy;
  view->popup.notify = layer_popup;
  view->output_destroy.notify = layer_output_destroy;
  wl_signal_add(&surface->output->events.destroy, &view->output_destroy);
  wl_signal_add(&surface->surface->events.commit, &view->commit);
  wl_signal_add(&surface->surface->events.map, &view->map);
  wl_signal_add(&surface->surface->events.unmap, &view->unmap);
  wl_signal_add(&surface->events.destroy, &view->destroy);
  wl_signal_add(&surface->events.new_popup, &view->popup);
  wl_list_insert(&shell->views, &view->link);
}

static void publish_outputs(struct telar_shell *shell) {
  struct wlr_output_configuration_v1 *config = wlr_output_configuration_v1_create();
  if (!config) {
    return;
  }
  struct telar_output *output;
  wl_list_for_each(output, &shell->server->outputs, link) {
    struct wlr_output_configuration_head_v1 *head =
        wlr_output_configuration_head_v1_create(config, output->wlr_output);
    if (!head) {
      wlr_output_configuration_v1_destroy(config);
      return;
    }
    struct wlr_output_layout_output *layout =
        wlr_output_layout_get(shell->server->output_layout, output->wlr_output);
    head->state.enabled = layout != NULL;
    if (layout) {
      head->state.x = layout->x;
      head->state.y = layout->y;
    }
  }
  wlr_output_manager_v1_set_configuration(shell->outputs, config);
}

void telar_shell_outputs(struct telar_server *server) {
  if (!server->shell || server->destroying) {
    return;
  }
  telar_update_visibility(server);
  arrange(server->shell);
  telar_lock_outputs(server);
  publish_outputs(server->shell);
}

static void layout_change(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, layout);
  telar_shell_outputs(shell->server);
}

static void configure_outputs(struct telar_shell *shell,
                              struct wlr_output_configuration_v1 *config,
                              bool apply) {
  bool valid = !shell->server->locked;
  unsigned enabled = 0;
  struct wlr_output_configuration_head_v1 *head;
  wl_list_for_each(head, &config->heads, link) {
    if (!head->state.enabled) {
      continue;
    }
    ++enabled;
    valid &= isfinite(head->state.scale) && head->state.scale >= 0.25 && head->state.scale <= 8 &&
             head->state.x >= -32768 && head->state.x <= 32768 && head->state.y >= -32768 &&
             head->state.y <= 32768;
  }
  size_t count = 0;
  struct wlr_backend_output_state *states =
      valid && enabled ? wlr_output_configuration_v1_build_state(config, &count) : NULL;
  bool ok = states && wlr_backend_test(shell->server->backend, states, count);
  if (ok && apply) {
    ok = wlr_backend_commit(shell->server->backend, states, count);
    // Publish actual state even if a backend could only commit part of it.
    wl_list_for_each(head, &config->heads, link) {
      if (head->state.output->enabled) {
        wlr_output_layout_add(shell->server->output_layout,
                              head->state.output,
                              head->state.x,
                              head->state.y);
      } else {
        wlr_output_layout_remove(shell->server->output_layout, head->state.output);
      }
    }
    telar_shell_outputs(shell->server);
  }
  for (size_t i = 0; i < count; ++i) {
    wlr_output_state_finish(&states[i].base);
  }
  free(states);
  if (ok) {
    wlr_output_configuration_v1_send_succeeded(config);
  } else {
    wlr_output_configuration_v1_send_failed(config);
  }
  wlr_output_configuration_v1_destroy(config);
}

static void output_apply(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, apply);
  configure_outputs(shell, data, true);
}

static void output_test(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, test);
  configure_outputs(shell, data, false);
}

static void output_power(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, power);
  struct wlr_output_power_v1_set_mode_event *event = data;
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, event->mode == ZWLR_OUTPUT_POWER_V1_MODE_ON);
  bool ready = true;
  if (!event->output->enabled && event->mode == ZWLR_OUTPUT_POWER_V1_MODE_ON) {
    // Replace the old scanout buffer atomically when waking an output. It may
    // still contain desktop pixels from before a lock established while off.
    struct wlr_scene_output *scene =
        wlr_scene_get_scene_output(shell->server->scene, event->output);
    ready = scene && wlr_scene_output_build_state(scene, &state, NULL);
  }
  if (ready) {
    wlr_output_commit_state(event->output, &state);
  }
  wlr_output_state_finish(&state);
}

void telar_shell_activity(struct telar_server *server) {
  if (server->idle) {
    wlr_idle_notifier_v1_notify_activity(server->idle, server->seat);
  }
}

void telar_shell_pointer(struct telar_server *server) {
  wlr_scene_node_set_position(&server->drag_tree->node, server->cursor->x, server->cursor->y);
  telar_shell_activity(server);
}

static void request_drag(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, request_drag);
  struct wlr_seat_request_start_drag_event *event = data;
  struct wlr_seat *seat = shell->server->seat;
  if (!shell->server->locked &&
      wlr_seat_validate_pointer_grab_serial(seat, event->origin, event->serial)) {
    wlr_seat_start_pointer_drag(seat, event->drag, event->serial);
  } else if (event->drag->source) {
    wlr_data_source_destroy(event->drag->source);
  }
}

static void start_drag(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, start_drag);
  struct wlr_drag *drag = data;
  shell->server->hooks.cancel_shortcuts(shell->server->hooks.context);
  if (drag->icon) {
    wlr_scene_drag_icon_create(shell->server->drag_tree, drag->icon);
    telar_shell_pointer(shell->server);
  }
}

static void inhibitor_destroy(struct wl_listener *listener, void *data) {
  struct inhibitor *inhibitor = wl_container_of(listener, inhibitor, destroy);
  struct telar_server *server = inhibitor->shell->server;
  wl_list_remove(&inhibitor->destroy.link);
  wl_list_remove(&inhibitor->link);
  free(inhibitor);
  telar_shell_visibility(server);
}

static void new_inhibitor(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, new_inhibitor);
  struct inhibitor *inhibitor = calloc(1, sizeof(*inhibitor));
  if (!inhibitor) {
    struct wlr_idle_inhibitor_v1 *source = data;
    wl_client_post_no_memory(wl_resource_get_client(source->resource));
    return;
  }
  inhibitor->shell = shell;
  inhibitor->source = data;
  inhibitor->destroy.notify = inhibitor_destroy;
  wl_signal_add(&inhibitor->source->events.destroy, &inhibitor->destroy);
  wl_list_insert(&shell->inhibitors, &inhibitor->link);
  telar_shell_visibility(shell->server);
}

static void activate(struct wl_listener *listener, void *data) {
  struct telar_shell *shell = wl_container_of(listener, shell, activation);
  struct wlr_xdg_activation_v1_request_activate_event *event = data;
  struct wlr_xdg_activation_token_v1 *token = event->token;
  // Only a recent input token from the focused surface may transfer focus.
  if (shell->server->locked || token->seat != shell->server->seat || !token->surface ||
      token->surface != shell->server->seat->keyboard_state.focused_surface) {
    return;
  }
  struct wlr_seat_client *client =
      wlr_seat_client_for_wl_client(token->seat, wl_resource_get_client(token->surface->resource));
  if (!client || !wlr_seat_client_validate_event_serial(client, token->serial)) {
    return;
  }
  telar_activate_surface(shell->server, event->surface);
}

static void decoration_mode(struct wl_listener *listener, void *data) {
  struct decoration *decoration = wl_container_of(listener, decoration, request);
  if (!decoration->source->toplevel->base->initialized) {
    return;
  }
  // Telar does not draw foreign titlebars. Let the application provide them.
  wlr_xdg_toplevel_decoration_v1_set_mode(decoration->source,
                                          WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
}

static void decoration_commit(struct wl_listener *listener, void *data) {
  struct decoration *decoration = wl_container_of(listener, decoration, commit);
  if (decoration->source->toplevel->base->initial_commit) {
    decoration_mode(&decoration->request, NULL);
  }
}

static void decoration_destroy(struct wl_listener *listener, void *data) {
  struct decoration *decoration = wl_container_of(listener, decoration, destroy);
  wl_list_remove(&decoration->request.link);
  wl_list_remove(&decoration->commit.link);
  wl_list_remove(&decoration->destroy.link);
  free(decoration);
}

static void new_decoration(struct wl_listener *listener, void *data) {
  struct wlr_xdg_toplevel_decoration_v1 *source = data;
  struct decoration *decoration = calloc(1, sizeof(*decoration));
  if (!decoration) {
    wl_client_post_no_memory(wl_resource_get_client(source->resource));
    return;
  }
  decoration->source = source;
  decoration->request.notify = decoration_mode;
  decoration->commit.notify = decoration_commit;
  wl_signal_add(&source->toplevel->base->surface->events.commit, &decoration->commit);
  decoration->destroy.notify = decoration_destroy;
  wl_signal_add(&source->events.request_mode, &decoration->request);
  wl_signal_add(&source->events.destroy, &decoration->destroy);
  decoration_mode(&decoration->request, NULL);
}

bool telar_shell_init(struct telar_server *server) {
  struct telar_shell *shell = calloc(1, sizeof(*shell));
  if (!shell) {
    return false;
  }
  shell->server = server;
  wl_list_init(&shell->views);
  wl_list_init(&shell->inhibitors);
  for (unsigned i = 0; i < 4; ++i) {
    shell->layers[i] = wlr_scene_tree_create(server->desktop_tree);
    if (!shell->layers[i]) {
      free(shell);
      return false;
    }
  }
  wlr_scene_node_place_below(&shell->layers[ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND]->node,
                             &server->layers[TELAR_WINDOWS]->node);
  wlr_scene_node_place_below(&shell->layers[ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM]->node,
                             &server->layers[TELAR_WINDOWS]->node);
  wlr_scene_node_place_below(&shell->layers[ZWLR_LAYER_SHELL_V1_LAYER_TOP]->node,
                             &server->fullscreen_tree->node);
  wlr_scene_node_place_below(&shell->layers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY]->node,
                             &server->popup_tree->node);

  struct wlr_layer_shell_v1 *layers = wlr_layer_shell_v1_create(server->wl_display, 4);
  shell->outputs = wlr_output_manager_v1_create(server->wl_display);
  struct wlr_output_power_manager_v1 *power =
      wlr_output_power_manager_v1_create(server->wl_display);
  server->idle = wlr_idle_notifier_v1_create(server->wl_display);
  struct wlr_idle_inhibit_manager_v1 *inhibit = wlr_idle_inhibit_v1_create(server->wl_display);
  struct wlr_xdg_activation_v1 *activation = wlr_xdg_activation_v1_create(server->wl_display);
  struct wlr_xdg_decoration_manager_v1 *decorations =
      wlr_xdg_decoration_manager_v1_create(server->wl_display);
  if (!layers || !shell->outputs || !power || !server->idle || !inhibit || !activation ||
      !decorations) {
    free(shell);
    return false;
  }
  if (!wlr_ext_output_image_capture_source_manager_v1_create(server->wl_display, 1) ||
      !wlr_ext_image_copy_capture_manager_v1_create(server->wl_display, 1)) {
    free(shell);
    return false;
  }
  struct wlr_xdg_foreign_registry *foreign = wlr_xdg_foreign_registry_create(server->wl_display);
  if (!foreign || !wlr_xdg_foreign_v1_create(server->wl_display, foreign) ||
      !wlr_xdg_foreign_v2_create(server->wl_display, foreign)) {
    free(shell);
    return false;
  }
  wlr_presentation_create(server->wl_display, server->backend, 2);
  wlr_single_pixel_buffer_manager_v1_create(server->wl_display);
  wlr_alpha_modifier_v1_create(server->wl_display);
  shell->new_layer.notify = new_layer;
  shell->apply.notify = output_apply;
  shell->test.notify = output_test;
  shell->layout.notify = layout_change;
  shell->power.notify = output_power;
  shell->request_drag.notify = request_drag;
  shell->start_drag.notify = start_drag;
  shell->new_inhibitor.notify = new_inhibitor;
  shell->activation.notify = activate;
  shell->decoration.notify = new_decoration;
  wl_signal_add(&layers->events.new_surface, &shell->new_layer);
  wl_signal_add(&shell->outputs->events.apply, &shell->apply);
  wl_signal_add(&shell->outputs->events.test, &shell->test);
  wl_signal_add(&server->output_layout->events.change, &shell->layout);
  wl_signal_add(&power->events.set_mode, &shell->power);
  wl_signal_add(&server->seat->events.request_start_drag, &shell->request_drag);
  wl_signal_add(&server->seat->events.start_drag, &shell->start_drag);
  wl_signal_add(&inhibit->events.new_inhibitor, &shell->new_inhibitor);
  wl_signal_add(&activation->events.request_activate, &shell->activation);
  wl_signal_add(&decorations->events.new_toplevel_decoration, &shell->decoration);
  server->shell = shell;
  return true;
}

void telar_shell_finish(struct telar_server *server) {
  struct telar_shell *shell = server->shell;
  if (!shell) {
    return;
  }
  wl_list_remove(&shell->new_layer.link);
  wl_list_remove(&shell->apply.link);
  wl_list_remove(&shell->test.link);
  wl_list_remove(&shell->layout.link);
  wl_list_remove(&shell->power.link);
  wl_list_remove(&shell->request_drag.link);
  wl_list_remove(&shell->start_drag.link);
  wl_list_remove(&shell->new_inhibitor.link);
  wl_list_remove(&shell->activation.link);
  wl_list_remove(&shell->decoration.link);
  free(shell);
  server->shell = NULL;
}
