#pragma once
#include "registry.h"

typedef struct telar_cursor telar_cursor;
telar_cursor *telar_cursor_create(void);
void telar_cursor_global(telar_cursor *, const telar_registry_global *);
void telar_cursor_remove(telar_cursor *, uint32_t name);
void telar_cursor_attach(telar_cursor *, struct wl_pointer *);
void telar_cursor_enter(telar_cursor *, uint32_t serial);
void telar_cursor_leave(telar_cursor *);
void telar_cursor_apply(telar_cursor *, uint32_t shape);
void telar_cursor_destroy(telar_cursor *);
