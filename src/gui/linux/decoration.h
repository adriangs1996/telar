#pragma once
#include <stdbool.h>
#include "registry.h"

struct xdg_toplevel;

// Window-thread owner. A decoration outlives its manager and precedes its toplevel.
typedef struct {
    struct zxdg_decoration_manager_v1 *manager;
    struct zxdg_toplevel_decoration_v1 *handle;
    uint32_t global, requested_mode, pending_mode, mode;
    bool attached;
} telar_decoration;

void telar_decoration_global(telar_decoration *self, const telar_registry_global *event);
void telar_decoration_remove(telar_decoration *self, uint32_t name);
bool telar_decoration_attach(telar_decoration *self, struct xdg_toplevel *toplevel);
void telar_decoration_apply(telar_decoration *self, uint32_t titlebar);
bool telar_decoration_acknowledge(telar_decoration *self);
void telar_decoration_deinit(telar_decoration *self);
