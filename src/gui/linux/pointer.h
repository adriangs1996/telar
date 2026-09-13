#ifndef TELAR_POINTER_H
#define TELAR_POINTER_H
#include <stdbool.h>
#include <wayland-client.h>
#include "../native/telar_gui.h"
#include "registry.h"

typedef struct telar_pointer telar_pointer;
telar_pointer *telar_pointer_create(void *context, const telar_gui_callbacks *callbacks);
void telar_pointer_attach(telar_pointer *, struct wl_seat *, bool available);
void telar_pointer_modifiers(telar_pointer *, uint32_t mods);
void telar_pointer_global(telar_pointer *, const telar_registry_global *);
void telar_pointer_remove(telar_pointer *, uint32_t name);
void telar_pointer_update(telar_pointer *);
void telar_pointer_destroy(telar_pointer *);
#endif
