#include "decoration.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include <string.h>

static void decoration_configure(void *data, struct zxdg_toplevel_decoration_v1 *handle, uint32_t mode) {
    (void)handle;
    telar_decoration *self = data;
    self->pending_mode = mode;
}

static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {.configure = decoration_configure};

void telar_decoration_global(telar_decoration *self, const telar_registry_global *event) {
    // Version 1 forbids creating a decoration after the toplevel has a buffer.
    // A global advertised after attach therefore applies to future windows only.
    if (self->attached || self->manager != NULL ||
        strcmp(event->interface, zxdg_decoration_manager_v1_interface.name) != 0) {
        return;
    }

    self->manager = wl_registry_bind(event->registry, event->name, &zxdg_decoration_manager_v1_interface, 1);
    if (self->manager != NULL) {
        self->global = event->name;
    }
}

void telar_decoration_remove(telar_decoration *self, uint32_t name) {
    if (self->manager != NULL && self->global == name) {
        zxdg_decoration_manager_v1_destroy(self->manager);
        self->manager = NULL;
        self->global = 0;
    }
}

// Attach before the first surface commit. No protocol means no native titlebar.
// Example: telar_decoration_attach(&window.decoration, window.toplevel).
bool telar_decoration_attach(telar_decoration *self, struct xdg_toplevel *toplevel) {
    if (self->attached) {
        return false;
    }

    self->attached = true;
    if (self->manager == NULL) {
        return true;
    }

    self->handle = zxdg_decoration_manager_v1_get_toplevel_decoration(self->manager, toplevel);
    if (self->handle == NULL) {
        return false;
    }

    zxdg_toplevel_decoration_v1_add_listener(self->handle, &decoration_listener, self);
    telar_decoration_apply(self, 1);
    return true;
}

// Fullscreen visibility belongs to xdg-shell; retain the user's normal-window
// preference while fullscreen, including changes received during that state.
// Example: telar_decoration_apply(&window.decoration, frame.titlebar).
void telar_decoration_apply(telar_decoration *self, uint32_t titlebar) {
    uint32_t mode = titlebar != 0 ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE :
                                  ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
    if (self->handle != NULL && self->requested_mode != mode) {
        zxdg_toplevel_decoration_v1_set_mode(self->handle, mode);
        self->requested_mode = mode;
    }
}

// Latch decoration state only with its enclosing xdg_surface.configure ACK.
// Example: if (!telar_decoration_acknowledge(&window.decoration)) return;
bool telar_decoration_acknowledge(telar_decoration *self) {
    if (self->pending_mode != 0) {
        self->mode = self->pending_mode;
        self->pending_mode = 0;
    }

    return self->handle == NULL || self->mode != 0;
}

void telar_decoration_deinit(telar_decoration *self) {
    if (self->handle != NULL) {
        zxdg_toplevel_decoration_v1_destroy(self->handle);
    }
    if (self->manager != NULL) {
        zxdg_decoration_manager_v1_destroy(self->manager);
    }

    memset(self, 0, sizeof *self);
}
