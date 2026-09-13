#pragma once
#include <stdbool.h>
#include "registry.h"

typedef struct telar_cursor_theme telar_cursor_theme;
typedef struct {
    struct wl_pointer *pointer;
    uint32_t serial, shape;
} telar_cursor_request;

telar_cursor_theme *telar_cursor_theme_create(void);
void telar_cursor_theme_global(telar_cursor_theme *, const telar_registry_global *);
void telar_cursor_theme_remove(telar_cursor_theme *, uint32_t name);
void telar_cursor_theme_apply(telar_cursor_theme *, const telar_cursor_request *);
void telar_cursor_theme_invalidate(telar_cursor_theme *);
void telar_cursor_theme_destroy(telar_cursor_theme *);
