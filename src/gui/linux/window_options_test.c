// Test generated Wayland requests and listeners without connecting to a desktop.
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "decoration.c"
#include "background_effect.c"
#include "xdg-shell-client-protocol.h"

struct fake_proxy {
    const struct wl_interface *interface;
    struct fake_proxy *parent;
    uint32_t version;
    bool alive;
    void *listener, *data;
};

static struct fake_proxy proxies[128];
static size_t proxy_count, mode_requests, blur_requests, opaque_requests;
static uint32_t last_mode;
static bool last_blur, last_opaque, fail_decoration;

static struct fake_proxy *proxy_new(const struct wl_interface *interface, uint32_t version) {
    assert(proxy_count < sizeof proxies / sizeof *proxies);
    struct fake_proxy *proxy = &proxies[proxy_count++];
    *proxy = (struct fake_proxy){.interface = interface, .version = version, .alive = true};
    return proxy;
}

uint32_t wl_proxy_get_version(struct wl_proxy *pointer) {
    struct fake_proxy *proxy = (void *)pointer;
    assert(proxy->alive);
    return proxy->version;
}

int wl_proxy_add_listener(struct wl_proxy *pointer, void (**listener)(void), void *data) {
    struct fake_proxy *proxy = (void *)pointer;
    assert(proxy->alive);
    proxy->listener = listener;
    proxy->data = data;
    return 0;
}

void wl_proxy_destroy(struct wl_proxy *pointer) {
    struct fake_proxy *proxy = (void *)pointer;
    assert(proxy->alive);
    for (size_t i = 0; i < proxy_count; i++) {
        assert(!proxies[i].alive || proxies[i].parent != proxy);
    }

    proxy->alive = false;
}

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *pointer, uint32_t opcode, const struct wl_interface *interface, uint32_t version, uint32_t flags, ...) {
    struct fake_proxy *proxy = (void *)pointer;
    assert(proxy->alive);
    if (flags & WL_MARSHAL_FLAG_DESTROY) {
        wl_proxy_destroy(pointer);
        return NULL;
    }

    if (interface == &zxdg_toplevel_decoration_v1_interface && fail_decoration) {
        return NULL;
    }

    va_list args;
    va_start(args, flags);
    struct fake_proxy *result = NULL;
    if (interface != NULL) {
        result = proxy_new(interface, version);
        if (interface == &zxdg_toplevel_decoration_v1_interface || interface == &ext_background_effect_surface_v1_interface) {
            (void)va_arg(args, void *);
            result->parent = va_arg(args, struct fake_proxy *);
            assert(result->parent->alive);
        }
    } else if (proxy->interface == &zxdg_toplevel_decoration_v1_interface && opcode == ZXDG_TOPLEVEL_DECORATION_V1_SET_MODE) {
        last_mode = va_arg(args, uint32_t);
        mode_requests++;
    } else if (proxy->interface == &ext_background_effect_surface_v1_interface && opcode == EXT_BACKGROUND_EFFECT_SURFACE_V1_SET_BLUR_REGION) {
        struct fake_proxy *region = va_arg(args, void *);
        assert(region == NULL || region->alive);
        last_blur = region != NULL;
        blur_requests++;
    } else if (proxy->interface == &wl_surface_interface && opcode == WL_SURFACE_SET_OPAQUE_REGION) {
        struct fake_proxy *region = va_arg(args, void *);
        assert(region == NULL || region->alive);
        last_opaque = region != NULL;
        opaque_requests++;
    }

    va_end(args);
    return (void *)result;
}

static void advertise(telar_decoration *self, uint32_t name) {
    const telar_registry_global global = {
        .registry = (void *)proxy_new(&wl_registry_interface, 1),
        .name = name,
        .version = 1,
        .interface = zxdg_decoration_manager_v1_interface.name,
    };
    telar_decoration_global(self, &global);
    wl_proxy_destroy((void *)global.registry);
}

static void configure(telar_decoration *self, uint32_t mode) {
    struct fake_proxy *handle = (void *)self->handle;
    const struct zxdg_toplevel_decoration_v1_listener *listener = handle->listener;
    listener->configure(handle->data, self->handle, mode);
}

static void verify_decoration(void) {
    telar_decoration self = {0};
    advertise(&self, 10);
    struct xdg_toplevel *toplevel = (void *)proxy_new(&xdg_toplevel_interface, 1);
    assert(telar_decoration_attach(&self, toplevel));
    assert(mode_requests == 1 && last_mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    assert(!telar_decoration_acknowledge(&self));
    configure(&self, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    assert(self.mode == 0); // Buffer attachment must still wait for xdg_surface.configure.
    assert(telar_decoration_acknowledge(&self));
    assert(self.mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    size_t requests = mode_requests, allocations = proxy_count;
    for (size_t i = 0; i < 1000; i++) {
        telar_decoration_apply(&self, 1);
    }

    assert(mode_requests == requests && proxy_count == allocations);
    telar_decoration_apply(&self, 0);
    assert(mode_requests == requests + 1 && last_mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    // A compositor may reject the preference. Repeated frames must not fight it.
    configure(&self, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    assert(telar_decoration_acknowledge(&self));
    telar_decoration_apply(&self, 0);
    assert(mode_requests == requests + 1);
    configure(&self, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    assert(self.mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    assert(telar_decoration_acknowledge(&self));
    assert(self.mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    // Fullscreen suppression can configure another mode without changing the
    // user's preferred normal-window titlebar, or causing a configure loop.
    telar_decoration_apply(&self, 1);
    requests = mode_requests;
    configure(&self, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    assert(telar_decoration_acknowledge(&self));
    telar_decoration_apply(&self, 1);
    configure(&self, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    assert(telar_decoration_acknowledge(&self));
    telar_decoration_apply(&self, 1);
    assert(mode_requests == requests);
    telar_decoration_remove(&self, 11);
    assert(self.manager != NULL);
    telar_decoration_remove(&self, 10);
    assert(self.manager == NULL && self.handle != NULL);
    telar_decoration_apply(&self, 0); // Existing children survive manager destruction.
    assert(mode_requests == requests + 1);
    advertise(&self, 12);
    assert(self.manager == NULL); // Never create a second decoration after mapping.
    telar_decoration_deinit(&self);
    telar_decoration_deinit(&self);
    xdg_toplevel_destroy(toplevel);
}

static void verify_missing_decoration(void) {
    telar_decoration self = {0};
    struct xdg_toplevel *toplevel = (void *)proxy_new(&xdg_toplevel_interface, 1);
    size_t requests = mode_requests;
    assert(telar_decoration_attach(&self, toplevel));
    assert(telar_decoration_acknowledge(&self));
    telar_decoration_apply(&self, 1);
    telar_decoration_apply(&self, 0);
    advertise(&self, 20); // Version 1 cannot be used for an already mapped window.
    assert(self.manager == NULL && self.handle == NULL && mode_requests == requests);
    telar_decoration_deinit(&self);
    xdg_toplevel_destroy(toplevel);
    advertise(&self, 21);
    telar_decoration_remove(&self, 21);
    advertise(&self, 22); // Re-advertisement is safe before the first attach.
    assert(self.manager != NULL);
    toplevel = (void *)proxy_new(&xdg_toplevel_interface, 1);
    fail_decoration = true;
    assert(!telar_decoration_attach(&self, toplevel));
    telar_decoration_deinit(&self);
    xdg_toplevel_destroy(toplevel);
    fail_decoration = false;
}

static void advertise_blur(telar_background_effect *self, uint32_t name) {
    telar_background_effect_global(self, name, ext_background_effect_manager_v1_interface.name);
    struct fake_proxy *manager = (void *)self->manager;
    const struct ext_background_effect_manager_v1_listener *listener = manager->listener;
    listener->capabilities(manager->data, self->manager, EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR);
}

static void verify_blur_radius(void) {
    telar_background_effect self = {
        .registry = (void *)proxy_new(&wl_registry_interface, 1),
        .compositor = (void *)proxy_new(&wl_compositor_interface, 4),
        .surface = (void *)proxy_new(&wl_surface_interface, 4),
    };
    advertise_blur(&self, 30);
    telar_gui_viewport viewport = {.width = 800, .height = 480, .scale = 1};
    telar_gui_frame frame = {.background = {0, 0, 0, 0.5f}, .background_blur = 1};
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 1 && last_blur && !last_opaque);
    size_t allocations = proxy_count, requests = opaque_requests;
    for (uint32_t radius = 1; radius <= 255; radius++) {
        frame.background_blur = radius;
        assert(telar_background_effect_apply(&self, viewport, &frame));
    }

    assert(blur_requests == 1 && proxy_count == allocations && opaque_requests == requests);
    frame.background_blur = 0;
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 2 && !last_blur);
    frame.background_blur = 20;
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 3 && last_blur);
    frame.background[3] = 1;
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 4 && !last_blur && last_opaque);
    frame.background[3] = 0.5f;
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 5 && last_blur && !last_opaque);
    viewport.width = 640;
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 6 && self.width == 640);
    capabilities(&self, self.manager, 0);
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 7 && !last_blur);
    telar_background_effect_remove(&self, 30);
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(self.manager == NULL && self.effect == NULL && !self.blurred);
    advertise_blur(&self, 31);
    assert(telar_background_effect_apply(&self, viewport, &frame));
    assert(blur_requests == 8 && last_blur);
    telar_background_effect_deinit(&self);
    telar_background_effect_deinit(&self);
    wl_surface_destroy(self.surface);
    wl_compositor_destroy(self.compositor);
    wl_registry_destroy(self.registry);
}

int main(void) {
    verify_decoration();
    verify_missing_decoration();
    verify_blur_radius();
    for (size_t i = 0; i < proxy_count; i++) {
        assert(!proxies[i].alive);
    }

    puts("native Wayland window options: titlebar negotiation, configure ordering, reload, lifecycle and numeric blur passed");
    return 0;
}
