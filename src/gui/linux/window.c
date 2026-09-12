// The Linux window: a Wayland toplevel through xdg-shell, painted by the
// Vulkan renderer whenever the compositor configures a size. No input yet.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "../native/telar_gui.h"
#include "renderer.h"
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
    telar_gui_render_fn render;
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

static void draw(window *self) {
    telar_gui_viewport viewport = {self->width, self->height, 1.0f};
    telar_gui_frame frame;
    memset(&frame, 0, sizeof frame);
    self->render(self->context, viewport, &frame);
    if (!telar_renderer_draw(self->renderer, viewport, &frame)) {
        self->failed = true;
        self->closing = true;
    }
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
    self->configured = true;
    draw(self);
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

int telar_gui_run(const char *title, void *context, telar_gui_render_fn render) {
    window self;
    memset(&self, 0, sizeof self);
    self.context = context;
    self.render = render;
    self.width = default_width;
    self.height = default_height;

    self.display = wl_display_connect(NULL);
    if (self.display == NULL) {
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

    while (!self.closing && wl_display_dispatch(self.display) != -1) {
    }

    int status = self.failed ? -1 : 0;
    destroy(&self);
    return status;
}
