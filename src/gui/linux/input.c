#define _POSIX_C_SOURCE 200809L
#include "input.h"
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PASTE_LIMIT (64 * 1024)
#define OFFER_LIMIT 16
struct offer { struct wl_data_offer *handle; bool utf8, plain; };
struct telar_input {
    void *context;
    telar_gui_callbacks callbacks;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct offer offers[OFFER_LIMIT];
    struct offer *selection;
    struct xkb_context *xkb;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
    struct xkb_compose_table *compose_table;
    struct xkb_compose_state *compose;
    int paste_fd;
    uint8_t paste[PASTE_LIMIT];
    size_t paste_len;
    int32_t repeat_rate, repeat_delay;
    uint32_t repeat_key;
    int64_t repeat_at;
};

static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool emit(telar_input *self, telar_gui_input event) {
    bool accepted = self->callbacks.input(self->context, event) != 0;
    if (!accepted) fprintf(stderr, "telar gui: native input capacity exceeded or input unavailable\n");
    return accepted;
}

static void begin_paste(telar_input *self) {
    if (self->selection == NULL || self->paste_fd >= 0) return;
    const char *mime = self->selection->utf8 ? "text/plain;charset=utf-8" : self->selection->plain ? "text/plain" : NULL;
    if (mime == NULL) return;
    int fds[2];
    if (pipe(fds) != 0) return;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    wl_data_offer_receive(self->selection->handle, mime, fds[1]);
    close(fds[1]);
    self->paste_fd = fds[0];
    self->paste_len = 0;
}

static void send_key(telar_input *self, uint32_t key, uint32_t phase) {
    if (self->state == NULL) return;
    xkb_keysym_t sym = xkb_state_key_get_one_sym(self->state, key + 8);
    uint32_t mods = (xkb_state_mod_name_is_active(self->state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0 ? 1 : 0) |
                    (xkb_state_mod_name_is_active(self->state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0 ? 2 : 0) |
                    (xkb_state_mod_name_is_active(self->state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0 ? 4 : 0);
    if ((mods & 5) == 5 && (sym == XKB_KEY_v || sym == XKB_KEY_V)) {
        if (phase == 1) begin_paste(self);
        return;
    }
    uint32_t code = 0;
    switch (sym) {
        case XKB_KEY_Return: case XKB_KEY_KP_Enter: code = 1; break;
        case XKB_KEY_Tab: case XKB_KEY_ISO_Left_Tab: code = 2; break;
        case XKB_KEY_BackSpace: code = 3; break;
        case XKB_KEY_Escape: code = 4; break;
        case XKB_KEY_Up: code = 5; break;
        case XKB_KEY_Down: code = 6; break;
        case XKB_KEY_Left: code = 7; break;
        case XKB_KEY_Right: code = 8; break;
        case XKB_KEY_Home: code = 9; break;
        case XKB_KEY_End: code = 10; break;
        case XKB_KEY_Delete: code = 11; break;
        case XKB_KEY_Page_Up: code = 12; break;
        case XKB_KEY_Page_Down: code = 13; break;
    }
    if (code != 0) {
        emit(self, (telar_gui_input){.kind = 3, .code = code, .mods = mods, .phase = phase});
        return;
    }
    if (mods & (2 | 4)) {
        uint32_t scalar = xkb_keysym_to_utf32(sym);
        if (scalar >= 32) emit(self, (telar_gui_input){.kind = 4, .code = scalar, .mods = mods, .phase = phase});
        return;
    }
    if (phase == 3) return;
    char text[128];
    int len = 0;
    if (self->compose != NULL) {
        xkb_compose_state_feed(self->compose, sym);
        switch (xkb_compose_state_get_status(self->compose)) {
            case XKB_COMPOSE_COMPOSING: return;
            case XKB_COMPOSE_COMPOSED:
                len = xkb_compose_state_get_utf8(self->compose, text, sizeof text);
                xkb_compose_state_reset(self->compose);
                break;
            case XKB_COMPOSE_CANCELLED: xkb_compose_state_reset(self->compose); return;
            default: break;
        }
    }
    if (len == 0) len = xkb_state_key_get_utf8(self->state, key + 8, text, sizeof text);
    if (len > 0 && (size_t)len < sizeof text) emit(self, (telar_gui_input){.kind = 1, .phase = phase, .text = (uint8_t *)text, .len = (size_t)len});
}

static void keymap(void *data, struct wl_keyboard *keyboard, uint32_t format, int fd, uint32_t size) {
    (void)keyboard;
    telar_input *self = data;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || size == 0 || size > 4 * 1024 * 1024) { close(fd); return; }
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || metadata.st_size < (off_t)size) { close(fd); return; }
    char *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (bytes == MAP_FAILED) return;
    struct xkb_keymap *replacement = NULL;
    if (bytes[size - 1] == 0) replacement = xkb_keymap_new_from_string(self->xkb, bytes, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
    munmap(bytes, size);
    if (replacement == NULL) return;
    struct xkb_state *state = xkb_state_new(replacement);
    if (state == NULL) { xkb_keymap_unref(replacement); return; }
    xkb_state_unref(self->state);
    xkb_keymap_unref(self->keymap);
    self->keymap = replacement;
    self->state = state;
}
static void keyboard_enter(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface, struct wl_array *keys) {
    (void)data; (void)keyboard; (void)serial; (void)surface; (void)keys;
}
static void keyboard_leave(void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface) {
    (void)keyboard; (void)serial; (void)surface;
    telar_input *self = data;
    self->repeat_at = 0;
    if (self->compose != NULL) xkb_compose_state_reset(self->compose);
}
static void keyboard_key(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)keyboard; (void)serial; (void)time;
    telar_input *self = data;
    send_key(self, key, state == WL_KEYBOARD_KEY_STATE_PRESSED ? 1 : 3);
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED && self->keymap != NULL && self->repeat_rate > 0 && xkb_keymap_key_repeats(self->keymap, key + 8)) {
        self->repeat_key = key;
        self->repeat_at = now_ms() + self->repeat_delay;
    } else if (self->repeat_key == key) self->repeat_at = 0;
}
static void modifiers(void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)keyboard; (void)serial;
    telar_input *self = data;
    if (self->state != NULL) xkb_state_update_mask(self->state, depressed, latched, locked, 0, 0, group);
}
static void repeat_info(void *data, struct wl_keyboard *keyboard, int32_t rate, int32_t delay) {
    (void)keyboard;
    telar_input *self = data;
    self->repeat_rate = rate < 0 ? 0 : rate > 1000 ? 1000 : rate;
    self->repeat_delay = delay < 0 ? 0 : delay;
    if (self->repeat_rate == 0) self->repeat_at = 0;
}
static const struct wl_keyboard_listener keyboard_listener = { keymap, keyboard_enter, keyboard_leave, keyboard_key, modifiers, repeat_info };
static void capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    telar_input *self = data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && self->keyboard == NULL) {
        self->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(self->keyboard, &keyboard_listener, self);
    } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && self->keyboard != NULL) {
        wl_keyboard_destroy(self->keyboard);
        self->keyboard = NULL;
        self->repeat_at = 0;
    }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) { (void)data; (void)seat; (void)name; }
static const struct wl_seat_listener seat_listener = { capabilities, seat_name };

static void offered(void *data, struct wl_data_offer *handle, const char *mime) {
    (void)handle;
    struct offer *offer = data;
    if (!strcmp(mime, "text/plain;charset=utf-8")) offer->utf8 = true;
    if (!strcmp(mime, "text/plain")) offer->plain = true;
}
static const struct wl_data_offer_listener offer_listener = { .offer = offered };
static void data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *handle) {
    (void)device;
    telar_input *self = data;
    for (size_t i = 0; i < OFFER_LIMIT; i++) {
        if (self->offers[i].handle == NULL) {
            self->offers[i] = (struct offer){.handle = handle};
            wl_data_offer_add_listener(handle, &offer_listener, &self->offers[i]);
            return;
        }
    }
    wl_data_offer_destroy(handle);
}
static void selection(void *data, struct wl_data_device *device, struct wl_data_offer *handle) {
    (void)device;
    telar_input *self = data;
    self->selection = NULL;
    for (size_t i = 0; i < OFFER_LIMIT; i++) {
        struct offer *offer = &self->offers[i];
        if (offer->handle == handle && handle != NULL) self->selection = offer;
        else if (offer->handle != NULL) {
            wl_data_offer_destroy(offer->handle);
            *offer = (struct offer){0};
        }
    }
}
static void drag_enter(void *data, struct wl_data_device *device, uint32_t serial, struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *offer) {
    (void)data; (void)device; (void)serial; (void)surface; (void)x; (void)y; (void)offer;
}
static void drag_leave(void *data, struct wl_data_device *device) { (void)data; (void)device; }
static void drag_motion(void *data, struct wl_data_device *device, uint32_t time, wl_fixed_t x, wl_fixed_t y) { (void)data; (void)device; (void)time; (void)x; (void)y; }
static void drag_drop(void *data, struct wl_data_device *device) { (void)data; (void)device; }
static const struct wl_data_device_listener data_listener = { data_offer, drag_enter, drag_leave, drag_motion, drag_drop, selection };

static void ensure_device(telar_input *self) {
    if (self->seat != NULL && self->manager != NULL && self->device == NULL) {
        self->device = wl_data_device_manager_get_data_device(self->manager, self->seat);
        wl_data_device_add_listener(self->device, &data_listener, self);
    }
}
telar_input *telar_input_create(void *context, const telar_gui_callbacks *callbacks) {
    telar_input *self = calloc(1, sizeof *self);
    if (self == NULL) return NULL;
    self->context = context;
    self->callbacks = *callbacks;
    self->paste_fd = -1;
    self->xkb = xkb_context_new(0);
    if (self->xkb == NULL) { free(self); return NULL; }
    const char *locale = getenv("LC_ALL");
    if (locale == NULL || !*locale) locale = getenv("LC_CTYPE");
    if (locale == NULL || !*locale) locale = getenv("LANG");
    if (locale == NULL || !*locale) locale = "C.UTF-8";
    self->compose_table = xkb_compose_table_new_from_locale(self->xkb, locale, 0);
    if (self->compose_table != NULL) self->compose = xkb_compose_state_new(self->compose_table, 0);
    return self;
}
void telar_input_global(telar_input *self, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (!strcmp(interface, wl_seat_interface.name) && self->seat == NULL) {
        self->seat = wl_registry_bind(registry, name, &wl_seat_interface, version < 5 ? version : 5);
        wl_seat_add_listener(self->seat, &seat_listener, self);
    } else if (!strcmp(interface, wl_data_device_manager_interface.name) && self->manager == NULL) {
        self->manager = wl_registry_bind(registry, name, &wl_data_device_manager_interface, 1);
    }
    ensure_device(self);
}
int telar_input_fd(telar_input *self) { return self->paste_fd; }
int telar_input_timeout(telar_input *self) {
    if (self->repeat_at == 0) return -1;
    int64_t wait = self->repeat_at - now_ms();
    return wait <= 0 ? 0 : wait > 10000 ? 10000 : (int)wait;
}
void telar_input_dispatch(telar_input *self) {
    if (self->repeat_at != 0 && now_ms() >= self->repeat_at) {
        send_key(self, self->repeat_key, 2);
        self->repeat_at = now_ms() + 1000 / self->repeat_rate;
    }
    if (self->paste_fd < 0) return;
    uint8_t chunk[4096];
    for (;;) {
        ssize_t len = read(self->paste_fd, chunk, sizeof chunk);
        if (len < 0 && errno == EINTR) continue;
        if (len < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (len > 0 && (size_t)len <= PASTE_LIMIT - self->paste_len) {
            memcpy(self->paste + self->paste_len, chunk, (size_t)len);
            self->paste_len += (size_t)len;
            continue;
        }
        if (len == 0) emit(self, (telar_gui_input){.kind = 2, .phase = 1, .text = self->paste, .len = self->paste_len});
        else fprintf(stderr, "telar gui: clipboard transfer failed or exceeded 64 KiB\n");
        close(self->paste_fd);
        self->paste_fd = -1;
        return;
    }
}
void telar_input_destroy(telar_input *self) {
    if (self == NULL) return;
    if (self->paste_fd >= 0) close(self->paste_fd);
    for (size_t i = 0; i < OFFER_LIMIT; i++) if (self->offers[i].handle != NULL) wl_data_offer_destroy(self->offers[i].handle);
    if (self->device != NULL) wl_data_device_destroy(self->device);
    if (self->manager != NULL) wl_data_device_manager_destroy(self->manager);
    if (self->keyboard != NULL) wl_keyboard_destroy(self->keyboard);
    if (self->seat != NULL) wl_seat_destroy(self->seat);
    xkb_compose_state_unref(self->compose);
    xkb_compose_table_unref(self->compose_table);
    xkb_state_unref(self->state);
    xkb_keymap_unref(self->keymap);
    xkb_context_unref(self->xkb);
    free(self);
}
