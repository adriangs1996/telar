#define _POSIX_C_SOURCE 200809L
// Exercise the actual listeners and generated protocol requests without a desktop.
// Proxy storage is bounded; every request is checked against its live owner.
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "cursor.c"
#include "cursor_theme.c"
#include "pointer.c"

struct fake_proxy {
    const struct wl_interface *interface;
    uint32_t version;
    bool alive;
    void *listener, *data;
};
static struct fake_proxy proxies[256];
static size_t proxy_count, shape_calls, surface_commits, set_cursor_calls;
static uint32_t last_shape, last_serial, desired_shape;
static int32_t last_scale, last_hotspot;
static struct wl_surface *last_surface;
static struct wl_buffer *last_buffer;
static telar_gui_input events[128];
static size_t event_count;

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
    proxy->alive = false;
}

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *pointer, uint32_t opcode, const struct wl_interface *interface, uint32_t version, uint32_t flags, ...) {
    struct fake_proxy *proxy = (void *)pointer;
    assert(proxy->alive);
    if (flags & WL_MARSHAL_FLAG_DESTROY) {
        wl_proxy_destroy(pointer);
        return NULL;
    }

    if (interface != NULL) {
        return (void *)proxy_new(interface, version);
    }

    va_list args;
    va_start(args, flags);
    if (proxy->interface == &wp_cursor_shape_device_v1_interface && opcode == WP_CURSOR_SHAPE_DEVICE_V1_SET_SHAPE) {
        last_serial = va_arg(args, uint32_t);
        last_shape = va_arg(args, uint32_t);
        shape_calls++;
    } else if (proxy->interface == &wl_pointer_interface && opcode == WL_POINTER_SET_CURSOR) {
        last_serial = va_arg(args, uint32_t);
        last_surface = va_arg(args, struct wl_surface *);
        last_hotspot = va_arg(args, int32_t);
        set_cursor_calls++;
    } else if (proxy->interface == &wl_surface_interface) {
        if (opcode == WL_SURFACE_COMMIT) {
            surface_commits++;
        } else if (opcode == WL_SURFACE_SET_BUFFER_SCALE) {
            last_scale = va_arg(args, int32_t);
        } else if (opcode == WL_SURFACE_ATTACH) {
            last_buffer = va_arg(args, struct wl_buffer *);
        }
    }

    va_end(args);
    return NULL;
}

struct fake_theme {
    bool alive;
    struct wl_cursor_image image;
    struct wl_cursor_image *images[1];
    struct wl_cursor cursor;
    struct wl_buffer *buffer;
};
static struct fake_theme themes[16];
static size_t theme_loads, image_preparations, theme_lookups;
static bool theme_fail;

struct wl_cursor_theme *wl_cursor_theme_load(const char *name, int size, struct wl_shm *shm) {
    (void)name;
    assert(shm != NULL);
    if (theme_fail) {
        theme_loads++;
        return NULL;
    }

    assert(theme_loads < sizeof themes / sizeof *themes);
    struct fake_theme *theme = &themes[theme_loads++];
    theme->alive = true;
    theme->image = (struct wl_cursor_image){.width = (uint32_t)size, .height = (uint32_t)size, .hotspot_x = (uint32_t)size / 4};
    theme->images[0] = &theme->image;
    theme->cursor = (struct wl_cursor){.image_count = 1, .images = theme->images};
    theme->buffer = (void *)proxy_new(&wl_buffer_interface, 1);
    return (void *)theme;
}

void wl_cursor_theme_destroy(struct wl_cursor_theme *pointer) {
    struct fake_theme *theme = (void *)pointer;
    assert(theme->alive);
    theme->alive = false;
    wl_proxy_destroy((void *)theme->buffer);
}

struct wl_cursor *wl_cursor_theme_get_cursor(struct wl_cursor_theme *pointer, const char *name) {
    struct fake_theme *theme = (void *)pointer;
    assert(theme->alive);
    theme_lookups++;
    // An old theme only supplies aliases; other shapes must use the default.
    if (!strcmp(name, "left_ptr") || !strcmp(name, "hand2") || !strcmp(name, "xterm")) {
        return &theme->cursor;
    }

    return NULL;
}

struct wl_buffer *wl_cursor_image_get_buffer(struct wl_cursor_image *image) {
    image_preparations++;
    for (size_t i = 0; i < sizeof themes / sizeof *themes; i++) {
        if (&themes[i].image == image) {
            assert(themes[i].alive);
            return themes[i].buffer;
        }
    }

    assert(false);
    return NULL;
}

static int capture(void *context, telar_gui_input event) {
    (void)context;
    assert(event_count < sizeof events / sizeof *events);
    events[event_count++] = event;
    return 1;
}

static uint32_t shape(void *context) {
    (void)context;
    return desired_shape;
}

static void global(telar_pointer *self, const char *interface, uint32_t name) {
    const telar_registry_global event = {.registry = (void *)proxy_new(&wl_registry_interface, 1), .name = name, .version = 6, .interface = interface};
    telar_pointer_global(self, &event);
    wl_proxy_destroy((void *)event.registry);
}

static telar_pointer *create(bool protocol) {
    telar_gui_callbacks callbacks = {.input = capture, .pointer_shape = shape};
    telar_pointer *self = telar_pointer_create(NULL, &callbacks);
    assert(self != NULL);
    global(self, wl_compositor_interface.name, 1);
    global(self, wl_shm_interface.name, 2);
    global(self, wl_output_interface.name, 3);
    if (protocol) {
        global(self, wp_cursor_shape_manager_v1_interface.name, 4);
    }

    struct wl_seat *seat = (void *)proxy_new(&wl_seat_interface, 5);
    telar_pointer_attach(self, seat, true);
    wl_proxy_destroy((void *)seat);
    return self;
}

static void verify_protocol(void) {
    telar_pointer *self = create(true);
    desired_shape = 3;
    telar_pointer_update(self);
    assert(shape_calls == 0);
    enter(self, self->handle, 81, NULL, wl_fixed_from_int(10), wl_fixed_from_int(20));
    assert(event_count == 1 && events[0].code == 6);
    telar_pointer_update(self);
    assert(shape_calls == 1 && last_serial == 81 && last_shape == 4 && theme_loads == 0);
    size_t previous = shape_calls;
    for (size_t i = 0; i < 1000; i++) {
        telar_pointer_update(self);
    }

    assert(shape_calls == previous);
    const uint32_t expected[TELAR_CURSOR_SHAPES] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,32,30,31,19,18,22,25,20,21,23,24,26,27,28,29,33,34};
    for (desired_shape = 0; desired_shape < TELAR_CURSOR_SHAPES; desired_shape++) {
        telar_pointer_update(self);
        assert(last_serial == 81 && last_shape == expected[desired_shape]);
    }

    telar_pointer_update(self);
    assert(last_shape == 1); // Out-of-range host values safely select default.
    telar_pointer_modifiers(self, 8);
    assert(event_count == 2 && events[1].code == 6 && events[1].mods == 8 && events[1].x == 10 && events[1].y == 20);
    telar_pointer_modifiers(self, 8);
    assert(event_count == 2);
    button(self, self->handle, 999, 0, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
    desired_shape = 8;
    telar_pointer_update(self);
    assert(last_serial == 81); // Button serials must never replace enter serials.
    leave(self, self->handle, 1000, NULL);
    assert(events[event_count - 2].code == 2 && events[event_count - 1].code == 7);
    previous = shape_calls;
    size_t previous_events = event_count;
    telar_pointer_modifiers(self, 0);
    telar_pointer_update(self);
    assert(shape_calls == previous && event_count == previous_events);
    enter(self, self->handle, 0, NULL, 0, 0);
    telar_pointer_update(self);
    assert(last_serial == 0 && shape_calls == previous + 1); // Serial zero is valid.
    telar_pointer_attach(self, NULL, false);
    assert(events[event_count - 1].code == 7);
    previous = shape_calls;
    telar_pointer_update(self);
    assert(shape_calls == previous);
    telar_pointer_destroy(self);
}

static void verify_fallback(void) {
    telar_pointer *self = create(false);
    desired_shape = 3;
    enter(self, self->handle, 51, NULL, 0, 0);
    telar_pointer_update(self);
    assert(theme_loads == 1 && set_cursor_calls == 1 && surface_commits == 1 && last_serial == 51 && last_scale == 1);
    assert(last_buffer != NULL && last_surface != NULL && last_hotspot == 6);
    size_t lookups = theme_lookups, preparations = image_preparations;
    size_t commits = surface_commits;
    for (size_t i = 0; i < 1000; i++) {
        telar_pointer_update(self);
    }

    assert(theme_lookups == lookups && image_preparations == preparations && theme_loads == 1 && surface_commits == commits);
    for (desired_shape = 0; desired_shape < TELAR_CURSOR_SHAPES; desired_shape++) {
        telar_pointer_update(self);
    }

    assert(theme_lookups == lookups && image_preparations == preparations && theme_loads == 1);
    telar_cursor_theme *theme = self->cursor->theme;
    output_scale(&theme->outputs[0], theme->outputs[0].handle, 2);
    surface_enter(theme, theme->surface, theme->outputs[0].handle);
    telar_pointer_update(self);
    assert(theme_loads == 2 && last_scale == 2 && last_hotspot == 6);
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
    preferred_scale(theme, theme->surface, 3);
    telar_pointer_update(self);
    assert(theme_loads == 3 && last_scale == 3 && last_hotspot == 6);
#endif
    global(self, wp_cursor_shape_manager_v1_interface.name, 4);
    commits = surface_commits;
    telar_pointer_update(self);
    assert(surface_commits == commits && last_serial == 51);
    telar_pointer_remove(self, 4);
    telar_pointer_update(self);
    assert(surface_commits == commits + 1 && last_serial == 51);
    leave(self, self->handle, 91, NULL);
    commits = surface_commits;
    telar_pointer_remove(self, 3);
    telar_pointer_update(self);
    assert(surface_commits == commits);
    enter(self, self->handle, 92, NULL, 0, 0);
    telar_pointer_update(self);
    assert(last_serial == 92 && surface_commits == commits + 1);
    self->callbacks.pointer_shape = NULL;
    telar_pointer_update(self);
    assert(theme->shape == 0);
    telar_pointer_remove(self, 2);
    commits = surface_commits;
    telar_pointer_update(self);
    assert(surface_commits == commits);
    global(self, wl_shm_interface.name, 5);
    theme_fail = true;
    size_t loads = theme_loads;
    telar_pointer_update(self);
    telar_pointer_update(self);
    assert(theme_loads == loads + 1); // A failed load is not retried on each pump.
    telar_pointer_destroy(self);
}

static void verify_legacy(void) {
    theme_fail = false;
    telar_pointer *self = create(false);
    telar_cursor_theme *theme = self->cursor->theme;
    ((struct fake_proxy *)theme->compositor)->version = 1;
    ((struct fake_proxy *)self->handle)->version = 2;
    desired_shape = 3;
    enter(self, self->handle, 123, NULL, 0, 0);
    telar_pointer_update(self);
    assert(theme->loaded_scale == 1);
    output_scale(&theme->outputs[0], theme->outputs[0].handle, 2);
    surface_enter(theme, theme->surface, theme->outputs[0].handle);
    telar_pointer_update(self);
    assert(theme->loaded_scale == 1 && last_serial == 123);
    telar_pointer_destroy(self);
}

int main(void) {
    assert(setenv("XCURSOR_SIZE", "24", 1) == 0);
    verify_protocol();
    verify_fallback();
    verify_legacy();
    for (size_t i = 0; i < proxy_count; i++) {
        assert(!proxies[i].alive);
    }

    puts("native Wayland cursor: shapes, serial, leave, modifiers, fallback, scaling and retained idle passed");
    return 0;
}
