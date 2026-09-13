#include "background_effect.h"
#include "ext-background-effect-v1-client-protocol.h"
#include <stdio.h>
#include <string.h>

static void capabilities(void *data, struct ext_background_effect_manager_v1 *manager, uint32_t flags) {
    (void)manager;
    telar_background_effect *self = data;
    self->capabilities = flags;
    self->dirty = true;
}

static const struct ext_background_effect_manager_v1_listener listener = {.capabilities = capabilities};

void telar_background_effect_global(telar_background_effect *self, uint32_t name, const char *interface) {
    if (self->manager == NULL && strcmp(interface, ext_background_effect_manager_v1_interface.name) == 0) {
        self->manager = wl_registry_bind(self->registry, name, &ext_background_effect_manager_v1_interface, 1);
        if (self->manager == NULL) {
            return;
        }
        ext_background_effect_manager_v1_add_listener(self->manager, &listener, self);
        self->global = name;
        self->dirty = true;
    }
}

void telar_background_effect_deinit(telar_background_effect *self) {
    if (self->effect != NULL) {
        ext_background_effect_surface_v1_destroy(self->effect);
        self->effect = NULL;
    }
    if (self->manager != NULL) {
        ext_background_effect_manager_v1_destroy(self->manager);
        self->manager = NULL;
    }
    self->capabilities = 0;
    self->global = 0;
    self->dirty = true;
}

void telar_background_effect_remove(telar_background_effect *self, uint32_t name) {
    if (self->manager != NULL && self->global == name) {
        telar_background_effect_deinit(self);
    }
}

// Surface state is double-buffered; Vulkan's following present commits it.
// Example: telar_background_effect_apply(&window.background, viewport, &frame).
bool telar_background_effect_apply(telar_background_effect *self, telar_gui_viewport viewport, const telar_gui_frame *frame) {
    bool opaque = frame->background[3] >= 1.0f;
    bool requested = !opaque && frame->background_blur != 0;
    bool blurred = requested && self->manager != NULL &&
                   (self->capabilities & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR);
    if (requested && !blurred && !self->warned) {
        fprintf(stderr, "telar gui: compositor does not advertise background blur; using transparency only\n");
        self->warned = true;
    }
    if (!self->dirty && self->configured && self->opaque == opaque && self->blurred == blurred &&
        self->width == viewport.width && self->height == viewport.height) {
        return true;
    }

    struct wl_region *region = wl_compositor_create_region(self->compositor);
    if (region == NULL) {
        return false;
    }
    wl_region_add(region, 0, 0, (int32_t)viewport.width, (int32_t)viewport.height);
    wl_surface_set_opaque_region(self->surface, opaque ? region : NULL);
    if (blurred && self->effect == NULL) {
        self->effect = ext_background_effect_manager_v1_get_background_effect(self->manager, self->surface);
        if (self->effect == NULL) {
            wl_region_destroy(region);
            return false;
        }
    }
    if (self->effect != NULL) {
        ext_background_effect_surface_v1_set_blur_region(self->effect, blurred ? region : NULL);
    }
    wl_region_destroy(region);
    self->configured = true;
    self->dirty = false;
    self->opaque = opaque;
    self->blurred = blurred;
    self->width = viewport.width;
    self->height = viewport.height;
    return true;
}
