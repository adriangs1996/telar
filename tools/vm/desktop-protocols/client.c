#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell.h"
#include "ext-session-lock-v1.h"
#include "wlr-layer-shell-unstable-v1.h"
#include "text-input-unstable-v3.h"
#include "input-method-unstable-v2.h"
#include "pointer-constraints-unstable-v1.h"
#include "relative-pointer-unstable-v1.h"
#include "wlr-output-power-management-unstable-v1.h"

enum {
  max_outputs = 16,
  fallback_width = 400,
  fallback_height = 240
};

struct client {
  struct wl_display *display;
  struct wl_compositor *compositor;
  struct wl_shm *shm;
  struct wl_seat *seat;
  struct xdg_wm_base *xdg;
  struct ext_session_lock_manager_v1 *locks;
  struct zwlr_layer_shell_v1 *layers;
  struct zwp_text_input_manager_v3 *texts;
  struct zwp_input_method_manager_v2 *methods;
  struct zwp_pointer_constraints_v1 *constraints;
  struct zwp_relative_pointer_manager_v1 *relatives;
  struct zwlr_output_power_manager_v1 *power_manager;
  struct zwlr_output_power_v1 *power;
  bool power_off, power_on;
  struct wl_pointer *pointer;
  bool pointer_locked;
  unsigned relative_events;
  wl_fixed_t pointer_x, pointer_y;
  struct wl_output *outputs[max_outputs];
  int output_count;
  struct wl_surface *surface;
  struct xdg_surface *xdg_surface;
  struct xdg_toplevel *toplevel;
  struct ext_session_lock_v1 *lock;
  struct zwp_text_input_v3 *text;
  struct zwp_input_method_v2 *method;
  int width, height;
  bool configured, fullscreen, maximized, locked, rejected, close;
  bool entered, preedit, committed, deleted, method_active, method_sent, deactivated;
  bool method_ready;
  uint32_t method_serial;
  const char *mode;
};

static uint64_t milliseconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return (uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void release(void *data, struct wl_buffer *buffer) {
  wl_buffer_destroy(buffer);
}

static void paint(struct client *client, struct wl_surface *surface, int width, int height) {
  assert(width > 0 && height > 0 && width <= 8192 && height <= 8192);
  size_t size = (size_t)width * height * 4;
  int fd = memfd_create("telar-protocol-test", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, size) == 0);
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  for (size_t i = 0; i < size / 4; ++i) {
    pixels[i] = client->lock ? 0xff243b25 : 0xff315080;
  }
  struct wl_shm_pool *pool = wl_shm_create_pool(client->shm, fd, size);
  struct wl_buffer *buffer =
      wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
  static const struct wl_buffer_listener listener = {.release = release};
  wl_buffer_add_listener(buffer, &listener, NULL);
  wl_shm_pool_destroy(pool);
  munmap(pixels, size);
  close(fd);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage_buffer(surface, 0, 0, width, height);
  wl_surface_commit(surface);
}

static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  xdg_wm_base_pong(base, serial);
}

static void registry_global(void *data,
                            struct wl_registry *registry,
                            uint32_t name,
                            const char *interface,
                            uint32_t version) {
  struct client *client = data;
#define BIND(field, type, supported)                                                               \
  if (!strcmp(interface, #type)) {                                                                 \
    client->field = wl_registry_bind(registry,                                                     \
                                     name,                                                         \
                                     &type##_interface,                                            \
                                     version < supported ? version : supported);                   \
    return;                                                                                        \
  }
  BIND(compositor, wl_compositor, 4)
  BIND(shm, wl_shm, 1)
  BIND(seat, wl_seat, 1)
  BIND(xdg, xdg_wm_base, 3)
  BIND(locks, ext_session_lock_manager_v1, 1)
  BIND(layers, zwlr_layer_shell_v1, 4)
  BIND(texts, zwp_text_input_manager_v3, 1)
  BIND(methods, zwp_input_method_manager_v2, 1)
  BIND(constraints, zwp_pointer_constraints_v1, 1)
  BIND(relatives, zwp_relative_pointer_manager_v1, 1)
  BIND(power_manager, zwlr_output_power_manager_v1, 1)
#undef BIND
  if (!strcmp(interface, "wl_output") && client->output_count < max_outputs) {
    client->outputs[client->output_count++] =
        wl_registry_bind(registry, name, &wl_output_interface, 1);
  }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {}

static void connect_client(struct client *client) {
  client->display = wl_display_connect(NULL);
  assert(client->display);
  struct wl_registry *registry = wl_display_get_registry(client->display);
  static const struct wl_registry_listener listener = {registry_global, registry_remove};
  wl_registry_add_listener(registry, &listener, client);
  assert(wl_display_roundtrip(client->display) >= 0);
  assert(client->compositor && client->shm && client->xdg && client->seat && client->output_count);
  static const struct xdg_wm_base_listener xdg_listener = {.ping = ping};
  xdg_wm_base_add_listener(client->xdg, &xdg_listener, client);
  wl_registry_destroy(registry);
}

static void surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
  struct client *client = data;
  xdg_surface_ack_configure(surface, serial);
  paint(client, client->surface, client->width, client->height);
  client->configured = true;
  printf("CONFIGURE %d %d fullscreen=%d maximized=%d\n",
         client->width,
         client->height,
         client->fullscreen,
         client->maximized);
}

static void toplevel_configure(void *data,
                               struct xdg_toplevel *toplevel,
                               int32_t width,
                               int32_t height,
                               struct wl_array *states) {
  struct client *client = data;
  client->width = width > 0 ? width : fallback_width;
  client->height = height > 0 ? height : fallback_height;
  client->fullscreen = client->maximized = false;
  uint32_t *state;
  wl_array_for_each(state, states) {
    client->fullscreen |= *state == XDG_TOPLEVEL_STATE_FULLSCREEN;
    client->maximized |= *state == XDG_TOPLEVEL_STATE_MAXIMIZED;
  }
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
  ((struct client *)data)->close = true;
}

static void window(struct client *client) {
  client->surface = wl_compositor_create_surface(client->compositor);
  client->xdg_surface = xdg_wm_base_get_xdg_surface(client->xdg, client->surface);
  static const struct xdg_surface_listener surface_listener = {.configure = surface_configure};
  xdg_surface_add_listener(client->xdg_surface, &surface_listener, client);
  client->toplevel = xdg_surface_get_toplevel(client->xdg_surface);
  static const struct xdg_toplevel_listener toplevel_listener = {
      .configure = toplevel_configure,
      .close = toplevel_close,
  };
  xdg_toplevel_add_listener(client->toplevel, &toplevel_listener, client);
  xdg_toplevel_set_app_id(client->toplevel, "telar.protocol-test");
  xdg_toplevel_set_title(client->toplevel, "Telar protocol probe");
  if (!strcmp(client->mode, "fullscreen")) {
    xdg_toplevel_set_fullscreen(client->toplevel, NULL);
  } else if (!strcmp(client->mode, "maximize")) {
    xdg_toplevel_set_maximized(client->toplevel);
  }
  wl_surface_commit(client->surface);
}

// Each lock surface needs both the client and its own wl_surface as callback data.
struct lock_view {
  struct client *client;
  struct wl_surface *surface;
};

static void lock_view_configure(void *data,
                                struct ext_session_lock_surface_v1 *surface,
                                uint32_t serial,
                                uint32_t width,
                                uint32_t height) {
  struct lock_view *view = data;
  ext_session_lock_surface_v1_ack_configure(surface, serial);
  paint(view->client, view->surface, width, height);
}

static void locked(void *data, struct ext_session_lock_v1 *lock) {
  ((struct client *)data)->locked = true;
  puts("LOCKED");
}

static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
  ((struct client *)data)->rejected = true;
  puts("LOCK_REJECTED");
}

static void lock_session(struct client *client) {
  assert(client->locks);
  client->lock = ext_session_lock_manager_v1_lock(client->locks);
  static const struct ext_session_lock_v1_listener listener = {.locked = locked,
                                                               .finished = lock_finished};
  ext_session_lock_v1_add_listener(client->lock, &listener, client);
  for (int i = 0; i < client->output_count; ++i) {
    struct lock_view *view = calloc(1, sizeof(*view));
    assert(view);
    view->client = client;
    view->surface = wl_compositor_create_surface(client->compositor);
    struct ext_session_lock_surface_v1 *surface =
        ext_session_lock_v1_get_lock_surface(client->lock, view->surface, client->outputs[i]);
    static const struct ext_session_lock_surface_v1_listener listener = {.configure =
                                                                             lock_view_configure};
    ext_session_lock_surface_v1_add_listener(surface, &listener, view);
  }
}

static void layer_configure(void *data,
                            struct zwlr_layer_surface_v1 *layer,
                            uint32_t serial,
                            uint32_t width,
                            uint32_t height) {
  struct client *client = data;
  zwlr_layer_surface_v1_ack_configure(layer, serial);
  paint(client, client->surface, width, height);
  client->configured = true;
  printf("LAYER %u %u\n", width, height);
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *layer) {
  ((struct client *)data)->close = true;
}

static void layer(struct client *client) {
  assert(client->layers);
  client->surface = wl_compositor_create_surface(client->compositor);
  struct zwlr_layer_surface_v1 *layer =
      zwlr_layer_shell_v1_get_layer_surface(client->layers,
                                            client->surface,
                                            NULL,
                                            ZWLR_LAYER_SHELL_V1_LAYER_TOP,
                                            "telar-protocol-test");
  static const struct zwlr_layer_surface_v1_listener listener = {layer_configure, layer_closed};
  zwlr_layer_surface_v1_add_listener(layer, &listener, client);
  zwlr_layer_surface_v1_set_anchor(layer,
                                   ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
  zwlr_layer_surface_v1_set_size(layer, 0, 48);
  zwlr_layer_surface_v1_set_exclusive_zone(layer, 48);
  wl_surface_commit(client->surface);
}

static void text_enter(void *data, struct zwp_text_input_v3 *text, struct wl_surface *surface) {
  struct client *client = data;
  client->entered = true;
  zwp_text_input_v3_enable(text);
  zwp_text_input_v3_set_surrounding_text(text, "abc", 3, 3);
  zwp_text_input_v3_set_content_type(text, 0, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
  zwp_text_input_v3_set_cursor_rectangle(text, 10, 10, 1, 20);
  zwp_text_input_v3_commit(text);
}

static void text_leave(void *data, struct zwp_text_input_v3 *text, struct wl_surface *surface) {}

static void text_preedit(void *data,
                         struct zwp_text_input_v3 *text,
                         const char *value,
                         int32_t begin,
                         int32_t end) {
  ((struct client *)data)->preedit |= value && !strcmp(value, "pin") && begin == 0 && end == 3;
}

static void text_commit(void *data, struct zwp_text_input_v3 *text, const char *value) {
  ((struct client *)data)->committed |= value && !strcmp(value, "拼");
}

static void
text_delete(void *data, struct zwp_text_input_v3 *text, uint32_t before, uint32_t after) {
  ((struct client *)data)->deleted |= before == 1 && after == 0;
}

static void text_done(void *data, struct zwp_text_input_v3 *text, uint32_t serial) {
  struct client *client = data;
  if (client->preedit && client->committed && client->deleted) {
    puts("IME_COMMIT_OK");
    zwp_text_input_v3_disable(text);
    zwp_text_input_v3_commit(text);
  }
}

static void method_activate(void *data, struct zwp_input_method_v2 *method) {
  struct client *client = data;
  client->method_active = true;
  client->method_ready = false;
  client->method_sent = false;
  client->deactivated = false;
}

static void method_deactivate(void *data, struct zwp_input_method_v2 *method) {
  ((struct client *)data)->method_active = false;
  ((struct client *)data)->deactivated = true;
  puts("IME_DEACTIVATE_OK");
}

static void method_surrounding(void *data,
                               struct zwp_input_method_v2 *method,
                               const char *text,
                               uint32_t cursor,
                               uint32_t anchor) {
  struct client *client = data;
  client->method_ready = !strcmp(text, "abc") && cursor == 3 && anchor == 3;
  if (client->method_ready) {
    puts("IME_SURROUNDING_OK");
  }
}

static void method_cause(void *data, struct zwp_input_method_v2 *method, uint32_t cause) {}

static void
method_content(void *data, struct zwp_input_method_v2 *method, uint32_t hint, uint32_t purpose) {}

static void method_done(void *data, struct zwp_input_method_v2 *method) {
  struct client *client = data;
  ++client->method_serial;
  if (client->method_active && client->method_ready && !client->method_sent) {
    client->method_sent = true;
    zwp_input_method_v2_set_preedit_string(method, "pin", 0, 3);
    zwp_input_method_v2_commit_string(method, "拼");
    zwp_input_method_v2_delete_surrounding_text(method, 1, 0);
    zwp_input_method_v2_commit(method, client->method_serial);
  }
}

static void method_unavailable(void *data, struct zwp_input_method_v2 *method) {
  fputs("Another input method is already running\n", stderr);
  exit(2);
}

static void input_method(struct client *app, struct client *method) {
  connect_client(method);
  assert(method->methods && app->texts);
  method->method = zwp_input_method_manager_v2_get_input_method(method->methods, method->seat);
  static const struct zwp_input_method_v2_listener method_listener = {
      method_activate,
      method_deactivate,
      method_surrounding,
      method_cause,
      method_content,
      method_done,
      method_unavailable,
  };
  zwp_input_method_v2_add_listener(method->method, &method_listener, method);
  wl_display_roundtrip(method->display);
  app->text = zwp_text_input_manager_v3_get_text_input(app->texts, app->seat);
  static const struct zwp_text_input_v3_listener text_listener = {
      .enter = text_enter,
      .leave = text_leave,
      .preedit_string = text_preedit,
      .commit_string = text_commit,
      .delete_surrounding_text = text_delete,
      .done = text_done,
  };
  zwp_text_input_v3_add_listener(app->text, &text_listener, app);
  window(app);
}

static void pointer_enter(void *data,
                          struct wl_pointer *pointer,
                          uint32_t serial,
                          struct wl_surface *surface,
                          wl_fixed_t x,
                          wl_fixed_t y) {
  struct client *client = data;
  client->pointer_x = x;
  client->pointer_y = y;
}

static void
pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface) {
}

static void
pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
  struct client *client = data;
  if (client->pointer_locked) {
    assert(client->pointer_x == x && client->pointer_y == y);
  }
  client->pointer_x = x;
  client->pointer_y = y;
}

static void pointer_button(void *data,
                           struct wl_pointer *pointer,
                           uint32_t serial,
                           uint32_t time,
                           uint32_t button,
                           uint32_t state) {}

static void pointer_axis(void *data,
                         struct wl_pointer *pointer,
                         uint32_t time,
                         uint32_t axis,
                         wl_fixed_t value) {}

static void pointer_locked(void *data, struct zwp_locked_pointer_v1 *pointer) {
  ((struct client *)data)->pointer_locked = true;
  puts("POINTER_LOCKED");
}

static void pointer_unlocked(void *data, struct zwp_locked_pointer_v1 *pointer) {
  ((struct client *)data)->pointer_locked = false;
  puts("POINTER_UNLOCKED");
}

static void relative_motion(void *data,
                            struct zwp_relative_pointer_v1 *pointer,
                            uint32_t high,
                            uint32_t low,
                            wl_fixed_t dx,
                            wl_fixed_t dy,
                            wl_fixed_t ux,
                            wl_fixed_t uy) {
  struct client *client = data;
  if (dx || dy) {
    ++client->relative_events;
    puts("RELATIVE_MOTION");
  }
}

static void pointer_lock(struct client *client) {
  assert(client->constraints && client->relatives);
  client->pointer = wl_seat_get_pointer(client->seat);
  static const struct wl_pointer_listener pointer_listener = {
      .enter = pointer_enter,
      .leave = pointer_leave,
      .motion = pointer_motion,
      .button = pointer_button,
      .axis = pointer_axis,
  };
  wl_pointer_add_listener(client->pointer, &pointer_listener, client);
  struct zwp_relative_pointer_v1 *relative =
      zwp_relative_pointer_manager_v1_get_relative_pointer(client->relatives, client->pointer);
  static const struct zwp_relative_pointer_v1_listener relative_listener = {.relative_motion =
                                                                                relative_motion};
  zwp_relative_pointer_v1_add_listener(relative, &relative_listener, client);
  struct zwp_locked_pointer_v1 *locked =
      zwp_pointer_constraints_v1_lock_pointer(client->constraints,
                                              client->surface,
                                              client->pointer,
                                              NULL,
                                              ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
  static const struct zwp_locked_pointer_v1_listener lock_listener = {.locked = pointer_locked,
                                                                      .unlocked = pointer_unlocked};
  zwp_locked_pointer_v1_add_listener(locked, &lock_listener, client);
}

static void power_mode(void *data, struct zwlr_output_power_v1 *power, uint32_t mode) {
  struct client *client = data;
  if (mode == ZWLR_OUTPUT_POWER_V1_MODE_OFF) {
    client->power_off = true;
    puts("OUTPUT_OFF");
  }
  client->power_on = mode == ZWLR_OUTPUT_POWER_V1_MODE_ON;
}

static void power_failed(void *data, struct zwlr_output_power_v1 *power) {
  assert(!"Output power management failed");
}

static void output_power(struct client *client) {
  assert(client->power_manager);
  client->power =
      zwlr_output_power_manager_v1_get_output_power(client->power_manager, client->outputs[0]);
  static const struct zwlr_output_power_v1_listener listener = {.mode = power_mode,
                                                                .failed = power_failed};
  zwlr_output_power_v1_add_listener(client->power, &listener, client);
  zwlr_output_power_v1_set_mode(client->power, ZWLR_OUTPUT_POWER_V1_MODE_OFF);
}

int main(int argc, char **argv) {
  assert(argc >= 2);
  setvbuf(stdout, NULL, _IOLBF, 0);
  struct client app = {.mode = argv[1]}, method = {0};
  connect_client(&app);
  if (!strcmp(app.mode, "power")) {
    output_power(&app);
  } else if (!strcmp(app.mode, "lock")) {
    lock_session(&app);
  } else if (!strcmp(app.mode, "layer")) {
    layer(&app);
  } else if (!strcmp(app.mode, "ime")) {
    input_method(&app, &method);
  } else {
    window(&app);
    if (!strcmp(app.mode, "pointer")) {
      pointer_lock(&app);
    }
  }
  uint64_t start = milliseconds();
  uint64_t duration = argc > 2 ? strtoul(argv[2], NULL, 10) : 5000;
  bool restored = false, mode_seen = false;
  while (!app.close && milliseconds() - start < duration) {
    struct client *clients[] = {&app, &method};
    struct pollfd fds[2] = {{wl_display_get_fd(app.display), POLLIN, 0}, {-1, POLLIN, 0}};
    if (method.display) {
      fds[1].fd = wl_display_get_fd(method.display);
    }
    for (int i = 0; i < 2; ++i) {
      if (clients[i]->display) {
        assert(wl_display_dispatch_pending(clients[i]->display) >= 0);
        wl_display_flush(clients[i]->display);
      }
    }
    assert(poll(fds, 2, 50) >= 0 || errno == EINTR);
    for (int i = 0; i < 2; ++i) {
      if (fds[i].revents & POLLIN) {
        assert(wl_display_dispatch(clients[i]->display) >= 0);
      }
    }
    if (app.power && !restored && milliseconds() - start > duration / 2) {
      zwlr_output_power_v1_set_mode(app.power, ZWLR_OUTPUT_POWER_V1_MODE_ON);
      restored = true;
    }
    mode_seen |= app.fullscreen || app.maximized;
    if (mode_seen && !restored && milliseconds() - start > duration / 2) {
      xdg_toplevel_unset_fullscreen(app.toplevel);
      xdg_toplevel_unset_maximized(app.toplevel);
      restored = true;
    }
    if (method.deactivated && app.committed) {
      assert(app.entered && app.preedit && app.committed && app.deleted);
      puts("PASS IME");
      break;
    }
  }
  if (app.power) {
    assert(app.power_off && app.power_on);
    puts("PASS OUTPUT_POWER");
  }
  if (app.lock) {
    assert(app.locked && !app.rejected);
    ext_session_lock_v1_unlock_and_destroy(app.lock);
    wl_display_roundtrip(app.display);
    puts("PASS LOCK_UNLOCK");
  }
  if (!strcmp(app.mode, "fullscreen") || !strcmp(app.mode, "maximize")) {
    assert(mode_seen && restored && !app.fullscreen && !app.maximized);
    puts("PASS WINDOW_STATE");
  }
  if (!strcmp(app.mode, "ime")) {
    assert(method.deactivated);
  }
  if (!strcmp(app.mode, "layer")) {
    assert(app.configured);
    puts("PASS LAYER");
  }
  if (!strcmp(app.mode, "pointer")) {
    assert(app.relative_events > 0);
    puts("PASS POINTER_LOCK");
  }
  wl_display_disconnect(app.display);
  if (method.display) {
    wl_display_disconnect(method.display);
  }
  return 0;
}
