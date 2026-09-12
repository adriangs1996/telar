// The Linux window: a Wayland toplevel through xdg-shell, painted by the
// Vulkan renderer consumes one sealed frame on its own worker.
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "../native/telar_gui.h"
#include "renderer.h"
#include "input.h"
#include "frame_worker.h"
#include "xdg-shell-client-protocol.h"

typedef struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct xdg_wm_base *shell;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    telar_renderer *renderer;
    void *context;
    telar_gui_callbacks callbacks;
    telar_input *input;
    telar_frame_worker *worker;
    bool dirty, in_flight;
    int64_t last_draw;
    uint32_t width;
    uint32_t height;
    bool configured;
    bool closing;
    bool failed;
} window;

static const uint32_t default_width = 800;
static const uint32_t default_height = 480;

static void shell_ping(void *data, struct xdg_wm_base *shell, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(shell, serial);
}

static const struct xdg_wm_base_listener shell_listener = {.ping = shell_ping};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    window *self = data;
    telar_input_global(self->input, registry, name, interface, version);
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        self->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        self->shell = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(self->shell, &shell_listener, self);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void draw(window *self) {
    if (!self->configured || self->in_flight || !self->dirty) return;
    if (now_ms() - self->last_draw < 17) return;
    telar_gui_viewport viewport = {self->width, self->height, 1.0f};
    telar_gui_frame frame;
    memset(&frame, 0, sizeof frame);
    self->callbacks.render(self->context, viewport, &frame);
    self->dirty = false;
    self->in_flight = true;
    self->last_draw = now_ms();
    telar_frame_worker_submit(self->worker, viewport, &frame);
}

static void surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    window *self = data;
    xdg_surface_ack_configure(surface, serial);
    if (self->renderer == NULL) {
        telar_gui_viewport viewport = {self->width, self->height, 1.0f};
        self->renderer = telar_renderer_create(self->display, self->surface, viewport);
        if (self->renderer == NULL) {
            self->failed = true;
            self->closing = true;
            return;
        }
    }
    if (self->worker == NULL) {
        self->worker = telar_frame_worker_create(self->renderer);
        if (self->worker == NULL) { self->failed = true; self->closing = true; return; }
    }
    self->configured = true;
    self->dirty = true;
}

static const struct xdg_surface_listener surface_listener = {.configure = surface_configure};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    (void)toplevel;
    (void)states;
    window *self = data;
    // Zero means the client picks; keep the last size then.
    if (width > 0 && height > 0) {
        self->width = (uint32_t)width;
        self->height = (uint32_t)height;
    }
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)toplevel;
    window *self = data;
    self->closing = true;
}

static void toplevel_configure_bounds(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height) {
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
}

static void toplevel_wm_capabilities(void *data, struct xdg_toplevel *toplevel, struct wl_array *capabilities) {
    (void)data;
    (void)toplevel;
    (void)capabilities;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

static void destroy(window *self) {
    telar_frame_worker_destroy(self->worker);
    telar_input_destroy(self->input);
    if (self->renderer != NULL) telar_renderer_destroy(self->renderer);
    if (self->toplevel != NULL) xdg_toplevel_destroy(self->toplevel);
    if (self->xdg_surface != NULL) xdg_surface_destroy(self->xdg_surface);
    if (self->surface != NULL) wl_surface_destroy(self->surface);
    if (self->shell != NULL) xdg_wm_base_destroy(self->shell);
    if (self->compositor != NULL) wl_compositor_destroy(self->compositor);
    if (self->registry != NULL) wl_registry_destroy(self->registry);
    if (self->display != NULL) {
        wl_display_flush(self->display);
        wl_display_disconnect(self->display);
    }
}

int telar_gui_run(const char *title, void *context, const telar_gui_callbacks *callbacks) {
    window self;
    memset(&self, 0, sizeof self);
    self.context = context;
    self.callbacks = *callbacks;
    self.input = telar_input_create(context, callbacks);
    if (self.input == NULL) return -1;
    self.width = default_width;
    self.height = default_height;

    self.display = wl_display_connect(NULL);
    if (self.display == NULL) {
        telar_input_destroy(self.input);
        fprintf(stderr, "telar gui: no Wayland display; set WAYLAND_DISPLAY\n");
        return -1;
    }
    self.registry = wl_display_get_registry(self.display);
    wl_registry_add_listener(self.registry, &registry_listener, &self);
    wl_display_roundtrip(self.display);
    if (self.compositor == NULL || self.shell == NULL) {
        fprintf(stderr, "telar gui: the compositor lacks wl_compositor or xdg_wm_base\n");
        destroy(&self);
        return -1;
    }

    self.surface = wl_compositor_create_surface(self.compositor);
    self.xdg_surface = xdg_wm_base_get_xdg_surface(self.shell, self.surface);
    xdg_surface_add_listener(self.xdg_surface, &surface_listener, &self);
    self.toplevel = xdg_surface_get_toplevel(self.xdg_surface);
    xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, &self);
    xdg_toplevel_set_title(self.toplevel, title);
    xdg_toplevel_set_app_id(self.toplevel, "telar");
    xdg_toplevel_set_min_size(self.toplevel, 320, 200);
    wl_surface_commit(self.surface);

    while (!self.closing) {
        while (wl_display_prepare_read(self.display) != 0) {
            if (wl_display_dispatch_pending(self.display) == -1) { self.failed = true; self.closing = true; break; }
        }
        if (self.closing) break;
        int flushed = wl_display_flush(self.display);
        bool write_blocked = flushed < 0 && errno == EAGAIN;
        if (flushed < 0 && !write_blocked) { wl_display_cancel_read(self.display); self.failed = true; break; }
        int timeout = telar_input_timeout(self.input);
        if (self.dirty && self.configured && !self.in_flight) {
            int64_t delay = self.last_draw + 17 - now_ms();
            int draw_timeout = delay <= 0 ? 0 : (int)delay;
            if (timeout < 0 || draw_timeout < timeout) timeout = draw_timeout;
        }
        struct pollfd fds[] = {
            {wl_display_get_fd(self.display), POLLIN | (write_blocked ? POLLOUT : 0), 0},
            {callbacks->wake_fd, POLLIN, 0},
            {telar_input_fd(self.input), POLLIN, 0},
            {self.worker != NULL ? telar_frame_worker_fd(self.worker) : -1, POLLIN, 0},
        };
        int ready = poll(fds, 4, timeout);
        if (ready < 0) {
            wl_display_cancel_read(self.display);
            if (errno == EINTR) continue;
            self.failed = true;
            break;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(self.display) == -1) { self.failed = true; break; }
        } else wl_display_cancel_read(self.display);
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) { self.failed = true; break; }
        if (wl_display_dispatch_pending(self.display) == -1) { self.failed = true; break; }
        if (fds[1].revents & POLLIN) telar_gui_drain(callbacks->wake_fd);
        telar_input_dispatch(self.input);
        if (self.worker != NULL && (fds[3].revents & POLLIN)) {
            uint64_t token;
            enum telar_render_result outcome;
            if (telar_frame_worker_take(self.worker, &token, &outcome)) {
                self.in_flight = false;
                callbacks->complete(context, token, outcome == TELAR_RENDER_DELIVERED);
                if (outcome == TELAR_RENDER_FAILED) { self.failed = true; break; }
                if (outcome == TELAR_RENDER_RETRY) self.dirty = true;
            }
        }
        int result = callbacks->pump(context);
        if (result < 0) break;
        if (result > 0) self.dirty = true;
        draw(&self);
    }

    int status = self.failed ? -1 : 0;
    destroy(&self);
    return status;
}

int telar_gui_clipboard(const uint8_t *bytes, size_t len) {
    (void)bytes; (void)len;
    return -1;
}
