#include "cursor.h"
#include "cursor_shapes.h"
#include "cursor_theme.h"
#include <stdlib.h>
#include <string.h>

struct telar_cursor {
    struct wl_pointer *pointer; // Borrowed; detach before its owner destroys it.
    struct wp_cursor_shape_manager_v1 *manager;
    struct wp_cursor_shape_device_v1 *device;
    telar_cursor_theme *theme;
    uint32_t global, serial, shape;
    bool entered, applied;
};

static void ensure_device(telar_cursor *self) {
    if (self->device == NULL && self->manager != NULL && self->pointer != NULL) {
        self->device = wp_cursor_shape_manager_v1_get_pointer(self->manager, self->pointer);
        self->applied = false;
    }
}

telar_cursor *telar_cursor_create(void) {
    telar_cursor *self = calloc(1, sizeof *self);
    if (self == NULL) {
        return NULL;
    }

    self->theme = telar_cursor_theme_create();
    if (self->theme == NULL) {
        free(self);
        return NULL;
    }

    return self;
}

void telar_cursor_global(telar_cursor *self, const telar_registry_global *global) {
    if (!strcmp(global->interface, wp_cursor_shape_manager_v1_interface.name) && self->manager == NULL) {
        self->manager = wl_registry_bind(global->registry, global->name, &wp_cursor_shape_manager_v1_interface, 1);
        self->global = global->name;
        ensure_device(self);
    }

    telar_cursor_theme_global(self->theme, global);
}

void telar_cursor_remove(telar_cursor *self, uint32_t name) {
    if (self->manager != NULL && self->global == name) {
        if (self->device != NULL) {
            wp_cursor_shape_device_v1_destroy(self->device);
            self->device = NULL;
        }

        wp_cursor_shape_manager_v1_destroy(self->manager);
        self->manager = NULL;
        self->global = 0;
        self->applied = false;
        telar_cursor_theme_invalidate(self->theme);
    }

    telar_cursor_theme_remove(self->theme, name);
}

void telar_cursor_attach(telar_cursor *self, struct wl_pointer *pointer) {
    if (self->device != NULL) {
        wp_cursor_shape_device_v1_destroy(self->device);
        self->device = NULL;
    }

    telar_cursor_leave(self);
    self->pointer = pointer;
    ensure_device(self);
}

// The enter serial belongs to pointer focus, never to a button or keyboard event.
// Example: telar_cursor_enter(cursor, enter_serial); telar_cursor_apply(cursor, 3);
void telar_cursor_enter(telar_cursor *self, uint32_t serial) {
    self->serial = serial;
    self->entered = true;
    self->applied = false;
    telar_cursor_theme_invalidate(self->theme);
}

void telar_cursor_leave(telar_cursor *self) {
    self->entered = false;
    self->applied = false;
}

// Called after the client pump; independent of dirty frames and GPU completion.
// Example: telar_cursor_apply(cursor, callbacks.pointer_shape(context));
void telar_cursor_apply(telar_cursor *self, uint32_t shape) {
    if (!self->entered || self->pointer == NULL) {
        return;
    }

    shape = shape < TELAR_CURSOR_SHAPES ? shape : 0;
    if (self->device != NULL) {
        if (!self->applied || shape != self->shape) {
            wp_cursor_shape_device_v1_set_shape(self->device, self->serial, telar_cursor_shapes[shape].protocol);
            self->shape = shape;
            self->applied = true;
        }

        return;
    }

    const telar_cursor_request request = {.pointer = self->pointer, .serial = self->serial, .shape = shape};
    telar_cursor_theme_apply(self->theme, &request);
}

void telar_cursor_destroy(telar_cursor *self) {
    if (self == NULL) {
        return;
    }

    telar_cursor_attach(self, NULL);
    if (self->manager != NULL) {
        wp_cursor_shape_manager_v1_destroy(self->manager);
    }

    telar_cursor_theme_destroy(self->theme);
    free(self);
}
