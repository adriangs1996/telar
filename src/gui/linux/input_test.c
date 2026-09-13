#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <time.h>

static int64_t test_time_ms = 1000;
static int test_clock_gettime(clockid_t clock, struct timespec *time) {
    assert(clock == CLOCK_MONOTONIC);
    *time = (struct timespec){.tv_sec = test_time_ms / 1000, .tv_nsec = test_time_ms % 1000 * 1000000};
    return 0;
}
#define clock_gettime test_clock_gettime
#include "input.c"
#undef clock_gettime

static telar_gui_input events[32];
static uint8_t text[32][8];
static size_t count;

static int capture(void *context, telar_gui_input event) {
    (void)context;
    assert(count < sizeof events / sizeof *events);
    assert(event.len <= sizeof text[0]);
    events[count] = event;
    if (event.len != 0) {
        memcpy(text[count], event.text, event.len);
        events[count].text = text[count];
    }
    count++;
    return 1;
}

static void verify_repeat(telar_input *self, uint32_t key, telar_gui_input expected) {
    count = 0;
    repeat_info(self, NULL, 25, 400);
    keyboard_key(self, NULL, 1, 0, key, WL_KEYBOARD_KEY_STATE_PRESSED);
    assert(count == 1 && events[0].phase == 1);
    assert(telar_input_timeout(self) == 400);
    test_time_ms += 399;
    telar_input_dispatch(self);
    assert(count == 1 && telar_input_timeout(self) == 1);
    test_time_ms++;
    telar_input_dispatch(self);
    assert(count == 2 && events[1].phase == 2 && telar_input_timeout(self) == 40);
    // A delayed loop emits one repeat, without replaying missed timer ticks.
    test_time_ms += 600;
    telar_input_dispatch(self);
    assert(count == 3 && events[2].phase == 2 && telar_input_timeout(self) == 40);
    keyboard_key(self, NULL, 2, 0, key, WL_KEYBOARD_KEY_STATE_RELEASED);
    assert(count == 4 && events[3].phase == 3 && telar_input_timeout(self) == -1);
    test_time_ms += 1000;
    telar_input_dispatch(self);
    assert(count == 4);
    for (size_t i = 0; i < 3; i++) {
        assert(events[i].kind == expected.kind && events[i].code == expected.code);
        assert(events[i].mods == expected.mods && events[i].physical == key + 1);
        assert(events[i].len == expected.len);
        assert(expected.len == 0 || memcmp(events[i].text, expected.text, expected.len) == 0);
    }
    assert(events[3].physical == key + 1 && self->held_keys[key].physical == 0);
}

int main(void) {
    telar_gui_callbacks callbacks = {.input = capture};
    telar_input *self = telar_input_create(NULL, &callbacks);
    assert(self != NULL);
    struct xkb_rule_names names = {.layout = "us"};
    self->keymap = xkb_keymap_new_from_names(self->xkb, &names, 0);
    assert(self->keymap != NULL);
    self->state = xkb_state_new(self->keymap);
    assert(self->state != NULL);

    verify_repeat(self, 36, (telar_gui_input){.kind = 1, .text = (const uint8_t *)"j", .len = 1});
    verify_repeat(self, 108, (telar_gui_input){.kind = 3, .code = 6});
    verify_repeat(self, 14, (telar_gui_input){.kind = 3, .code = 3});
    xkb_mod_index_t ctrl = xkb_keymap_mod_get_index(self->keymap, XKB_MOD_NAME_CTRL);
    assert(ctrl < 32);
    modifiers(self, NULL, 0, 1u << ctrl, 0, 0, 0);
    verify_repeat(self, 36, (telar_gui_input){.kind = 4, .code = 'j', .mods = 4});
    xkb_mod_index_t logo = xkb_keymap_mod_get_index(self->keymap, XKB_MOD_NAME_LOGO);
    assert(logo < 32);
    modifiers(self, NULL, 0, (1u << ctrl) | (1u << logo), 0, 0, 0);
    // Super is exposed to pointer hover without widening the keyboard ABI.
    verify_repeat(self, 36, (telar_gui_input){.kind = 4, .code = 'j', .mods = 4});
    modifiers(self, NULL, 0, 0, 0, 0, 0);

    count = 0;
    keyboard_key(self, NULL, 1, 0, 36, WL_KEYBOARD_KEY_STATE_PRESSED);
    modifiers(self, NULL, 0, (1u << ctrl) | (1u << logo), 0, 0, 0);
    keyboard_leave(self, NULL, 2, NULL);
    assert(xkb_state_serialize_mods(self->state, XKB_STATE_MODS_EFFECTIVE) == 0);
    assert(count == 3 && events[1].phase == 3 && events[2].kind == 5 && events[2].code == 0);
    assert(telar_input_timeout(self) == -1);
    test_time_ms += 1000;
    telar_input_dispatch(self);
    assert(count == 3);

    count = 0;
    keyboard_key(self, NULL, 3, 0, 36, WL_KEYBOARD_KEY_STATE_PRESSED);
    repeat_info(self, NULL, 0, 400);
    assert(telar_input_timeout(self) == -1);
    test_time_ms += 1000;
    telar_input_dispatch(self);
    assert(count == 1);
    keyboard_key(self, NULL, 4, 0, 36, WL_KEYBOARD_KEY_STATE_RELEASED);
    assert(count == 2 && events[1].phase == 3);
    telar_input_destroy(self);
    puts("native Wayland keyboard: delay, rate, repeat, release, focus and disabled repeat passed");
    return 0;
}
