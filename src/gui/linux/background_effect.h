#pragma once
#include <stdbool.h>
#include <wayland-client.h>
#include "../native/telar_gui.h"

// One window-thread owner. The registry, compositor and surface are borrowed.
typedef struct {
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_surface *surface;
    struct ext_background_effect_manager_v1 *manager;
    struct ext_background_effect_surface_v1 *effect;
    uint32_t global, capabilities, width, height;
    bool dirty, configured, opaque, blurred, warned;
} telar_background_effect;

void telar_background_effect_global(telar_background_effect *self, uint32_t name, const char *interface);
void telar_background_effect_remove(telar_background_effect *self, uint32_t name);
bool telar_background_effect_apply(telar_background_effect *self, telar_gui_viewport viewport, const telar_gui_frame *frame);
void telar_background_effect_deinit(telar_background_effect *self);
