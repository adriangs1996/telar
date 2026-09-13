#include "pointer.h"
#include "cursor.h"
#include <linux/input-event-codes.h>
#include <math.h>
#include <stdlib.h>

struct telar_pointer {
    void *context;
    telar_gui_callbacks callbacks;
    struct wl_pointer *handle;
    telar_cursor *cursor;
    bool entered;
    double x, y, axis, remainder;
    int32_t discrete;
    uint32_t mods, buttons;
};

static bool emit(telar_pointer *self, uint32_t code, uint32_t button) {
    return self->callbacks.input(self->context, (telar_gui_input){
        .kind = 6, .code = code, .phase = 1, .button = button,
        .mods = self->mods, .x = self->x, .y = self->y}) != 0;
}

static void enter(void *data, struct wl_pointer *handle, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)handle; (void)surface;
    telar_pointer *self = data;
    self->entered = true;
    telar_cursor_enter(self->cursor, serial);
    self->x = wl_fixed_to_double(x);
    self->y = wl_fixed_to_double(y);
    emit(self, 6, 0);
}

static void release_buttons(telar_pointer *self) {
    for (uint32_t button = 0; button < 3; button++) {
        if (self->buttons & (1u << button)) {
            emit(self, 2, button);
        }
    }

    self->buttons = 0;
}

static void leave(void *data, struct wl_pointer *handle, uint32_t serial, struct wl_surface *surface) {
    (void)handle; (void)serial; (void)surface;
    telar_pointer *self = data;
    release_buttons(self);
    self->axis = self->remainder = 0;
    self->discrete = 0;
    if (self->entered) {
        emit(self, 7, 0);
    }

    self->entered = false;
    telar_cursor_leave(self->cursor);
}

static void motion(void *data, struct wl_pointer *handle, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)handle; (void)time;
    telar_pointer *self = data;
    self->x = wl_fixed_to_double(x);
    self->y = wl_fixed_to_double(y);
    if (self->buttons == 0) {
        emit(self, 6, 0);
        return;
    }

    for (uint32_t button = 0; button < 3; button++) {
        if (self->buttons & (1u << button)) {
            emit(self, 3, button);
        }
    }
}

static void button(void *data, struct wl_pointer *handle, uint32_t serial, uint32_t time, uint32_t native_button, uint32_t state) {
    (void)handle; (void)serial; (void)time;
    telar_pointer *self = data;
    uint32_t value;
    switch (native_button) {
        case BTN_LEFT: value = 0; break;
        case BTN_MIDDLE: value = 1; break;
        case BTN_RIGHT: value = 2; break;
        default: return;
    }

    bool pressed = state == WL_POINTER_BUTTON_STATE_PRESSED;
    if (emit(self, pressed ? 1 : 2, value)) {
        if (pressed) {
            self->buttons |= 1u << value;
        } else {
            self->buttons &= ~(1u << value);
        }
    }
}

static void frame(void *data, struct wl_pointer *handle) {
    (void)handle;
    telar_pointer *self = data;
    double delta = self->discrete != 0 ? self->discrete : self->axis / 10;
    self->remainder = fmax(-32, fmin(32, self->remainder + delta));
    self->axis = 0;
    self->discrete = 0;
    while (fabs(self->remainder) >= 1) {
        bool up = self->remainder < 0;
        if (!emit(self, up ? 4 : 5, 0)) {
            self->remainder = 0;
            return;
        }

        self->remainder += up ? 1 : -1;
    }
}

static void axis(void *data, struct wl_pointer *handle, uint32_t time, uint32_t direction, wl_fixed_t value) {
    (void)time;
    telar_pointer *self = data;
    if (direction != WL_POINTER_AXIS_VERTICAL_SCROLL) {
        return;
    }

    self->axis += wl_fixed_to_double(value);
    if (wl_pointer_get_version(handle) < WL_POINTER_FRAME_SINCE_VERSION) {
        frame(data, handle);
    }
}

static void axis_source(void *data, struct wl_pointer *handle, uint32_t source) {
    (void)data; (void)handle; (void)source;
}

static void axis_stop(void *data, struct wl_pointer *handle, uint32_t time, uint32_t direction) {
    (void)data; (void)handle; (void)time; (void)direction;
}

static void axis_discrete(void *data, struct wl_pointer *handle, uint32_t direction, int32_t discrete) {
    (void)handle;
    telar_pointer *self = data;
    if (direction == WL_POINTER_AXIS_VERTICAL_SCROLL) {
        self->discrete = (int32_t)fmax(-32, fmin(32, (double)self->discrete + discrete));
    }
}

static const struct wl_pointer_listener listener = {
    .enter = enter, .leave = leave, .motion = motion, .button = button,
    .axis = axis, .frame = frame, .axis_source = axis_source,
    .axis_stop = axis_stop, .axis_discrete = axis_discrete,
};

telar_pointer *telar_pointer_create(void *context, const telar_gui_callbacks *callbacks) {
    telar_pointer *self = calloc(1, sizeof *self);
    if (self != NULL) {
        self->context = context;
        self->callbacks = *callbacks;
        self->cursor = telar_cursor_create();
        if (self->cursor == NULL) {
            free(self);
            return NULL;
        }
    }

    return self;
}

void telar_pointer_attach(telar_pointer *self, struct wl_seat *seat, bool available) {
    if (available && self->handle == NULL) {
        self->handle = wl_seat_get_pointer(seat);
        if (self->handle != NULL) {
            telar_cursor_attach(self->cursor, self->handle);
            wl_pointer_add_listener(self->handle, &listener, self);
        }
    } else if (!available && self->handle != NULL) {
        leave(self, self->handle, 0, NULL);
        telar_cursor_attach(self->cursor, NULL);
        if (wl_pointer_get_version(self->handle) >= WL_POINTER_RELEASE_SINCE_VERSION) {
            wl_pointer_release(self->handle);
        } else {
            wl_pointer_destroy(self->handle);
        }
        self->handle = NULL;
    }
}

void telar_pointer_modifiers(telar_pointer *self, uint32_t mods) {
    mods &= 15;
    if (self->mods == mods) {
        return;
    }

    self->mods = mods;
    if (self->entered) {
        emit(self, 6, 0);
    }
}

void telar_pointer_global(telar_pointer *self, const telar_registry_global *global) {
    telar_cursor_global(self->cursor, global);
}

void telar_pointer_remove(telar_pointer *self, uint32_t name) {
    telar_cursor_remove(self->cursor, name);
}

void telar_pointer_update(telar_pointer *self) {
    uint32_t shape = self->callbacks.pointer_shape != NULL ? self->callbacks.pointer_shape(self->context) : 0;
    telar_cursor_apply(self->cursor, shape);
}

void telar_pointer_destroy(telar_pointer *self) {
    if (self == NULL) {
        return;
    }

    telar_pointer_attach(self, NULL, false);
    telar_cursor_destroy(self->cursor);
    free(self);
}
