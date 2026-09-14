#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include "text_input.c"

struct proxy { bool alive; };
static struct proxy proxy = {.alive = true};
static unsigned commits, enables, disables, surrounding_calls, rectangle_calls;
static char sent_surrounding[4001];
static int32_t sent_cursor, sent_anchor, rectangle[4];
static telar_gui_text_context context;
static telar_gui_input events[16];
static uint8_t event_text[16][TELAR_GUI_TEXT_CAPACITY + 1];
static size_t event_count;
static bool context_pending;
static uint32_t last_cause;

uint32_t wl_proxy_get_version(struct wl_proxy *object) {
    assert(object == (void *)&proxy && proxy.alive);
    return 1;
}

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *object, uint32_t opcode, const struct wl_interface *interface, uint32_t version, uint32_t flags, ...) {
    (void)interface; (void)version;
    assert(object == (void *)&proxy && proxy.alive);
    va_list args;
    va_start(args, flags);
    if (opcode == ZWP_TEXT_INPUT_V3_COMMIT) commits++;
    if (opcode == ZWP_TEXT_INPUT_V3_ENABLE) enables++;
    if (opcode == ZWP_TEXT_INPUT_V3_DISABLE) disables++;
    if (opcode == ZWP_TEXT_INPUT_V3_SET_TEXT_CHANGE_CAUSE) last_cause = va_arg(args, uint32_t);
    if (opcode == ZWP_TEXT_INPUT_V3_SET_SURROUNDING_TEXT) {
        const char *text = va_arg(args, const char *);
        assert(strlen(text) <= 4000);
        strcpy(sent_surrounding, text);
        sent_cursor = va_arg(args, int32_t);
        sent_anchor = va_arg(args, int32_t);
        surrounding_calls++;
    }
    if (opcode == ZWP_TEXT_INPUT_V3_SET_CURSOR_RECTANGLE) {
        for (unsigned i = 0; i < 4; i++) rectangle[i] = va_arg(args, int32_t);
        rectangle_calls++;
    }
    va_end(args);
    if (flags & WL_MARSHAL_FLAG_DESTROY) proxy.alive = false;
    return NULL;
}

static int read_context(void *unused, telar_gui_text_context *output) {
    (void)unused;
    if (context_pending) return -1;
    *output = context;
    return context.enabled != 0;
}

static int capture(void *unused, telar_gui_input event) {
    (void)unused;
    assert(event_count < 16 && event.len <= TELAR_GUI_TEXT_CAPACITY);
    events[event_count] = event;
    if (event.len != 0) memcpy(event_text[event_count], event.text, event.len);
    events[event_count].text = event_text[event_count];
    event_count++;
    return 1;
}

int main(void) {
    telar_gui_callbacks callbacks = {.input = capture, .text_context = read_context};
    telar_text_input *self = telar_text_input_create(NULL, &callbacks);
    assert(self != NULL);
    self->handle = (void *)&proxy;
    context = (telar_gui_text_context){.enabled = 1, .target_id = 41, .generation = 7, .revision = 1,
        .text = (const uint8_t *)"ab", .len = 2, .selection_start = 1, .selection_end = 1,
        .x = 10.5, .y = 25.5, .width = 2, .height = 17};
    enter(self, self->handle, NULL);
    assert(commits == 1 && enables == 1 && surrounding_calls == 1);
    assert(!strcmp(sent_surrounding, "ab") && sent_cursor == 1 && sent_anchor == 1);
    assert(rectangle_calls == 1 && rectangle[0] == 10 && rectangle[1] == 25 && rectangle[3] == 17);
    telar_text_input_update(self);
    assert(commits == 1); // Repeated pump has no protocol work when context is unchanged.

    preedit_string(self, self->handle, "ni", 1, 2);
    assert(event_count == 0);
    done(self, self->handle, 1);
    assert(event_count == 1 && events[0].kind == 7 && events[0].code == 1 && events[0].target_id == 41);
    assert(events[0].selection_start == 1 && events[0].selection_end == 2);
    assert(events[0].len == 2 && !memcmp(events[0].text, "ni", 2));

    event_count = 0;
    delete_surrounding(self, self->handle, 1, 0);
    commit_string(self, self->handle, "\xe4\xbd\xa0");
    done(self, self->handle, 1);
    assert(event_count == 2 && events[0].kind == 1 && events[1].kind == 7 && events[1].code == 2);
    assert(events[0].replacement_start == 0 && events[0].replacement_end == 1 && events[0].len == 3);
    assert(events[0].generation == 7);

    context.target_id = 42;
    context.generation = 8;
    telar_text_input_update(self);
    assert(commits == 3 && disables == 1 && enables == 2);
    event_count = 0;
    commit_string(self, self->handle, "old");
    done(self, self->handle, 1);
    assert(event_count == 0); // Disabled editing sessions cannot deliver delayed commits.
    context.revision++;
    telar_text_input_update(self);
    assert(commits == 4); // A retired session cannot block the current context.
    done(self, self->handle, 3);
    context.revision++;
    telar_text_input_update(self);
    assert(commits == 4);
    done(self, self->handle, 4);
    telar_text_input_update(self);
    assert(commits == 5);

    event_count = 0;
    preedit_string(self, self->handle, "\xe4\xbd\xa0", 1, 2);
    done(self, self->handle, 5);
    assert(event_count == 0); // UTF-8 selections never split a scalar.
    delete_surrounding(self, self->handle, 100, 0);
    commit_string(self, self->handle, "lost");
    done(self, self->handle, 5);
    assert(event_count == 0); // Invalid deletion cannot partially commit.

    uint8_t long_text[TELAR_GUI_TEXT_CAPACITY];
    memset(long_text, 'x', sizeof long_text);
    context.text = long_text;
    context.len = sizeof long_text;
    context.selection_start = context.selection_end = sizeof long_text;
    context.revision++;
    telar_text_input_update(self);
    assert(strlen(sent_surrounding) == 4000 && sent_cursor == 4000 && sent_anchor == 4000);
    preedit_string(self, self->handle, "pending", 7, 7);
    done(self, self->handle, self->serial);
    assert(self->composing);
    event_count = 0;
    leave(self, self->handle, NULL);
    assert(event_count == 1 && events[0].kind == 7 && events[0].code == 2);
    assert(!self->enabled && !self->composing);
    context.text = (const uint8_t *)"ab";
    context.len = 2;
    context.selection_start = context.selection_end = 1;
    context.revision++;
    enter(self, self->handle, NULL);
    assert(last_cause == ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
    event_count = 0;
    commit_string(self, self->handle, "界");
    done(self, self->handle, self->serial);
    context.text = (const uint8_t *)"a界b";
    context.len = 5;
    context.selection_start = context.selection_end = 4;
    context.revision++;
    telar_text_input_update(self);
    assert(last_cause == ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD);
    context.selection_start = 4;
    context.selection_end = 1;
    context.revision++;
    telar_text_input_update(self);
    assert(last_cause == ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER && sent_cursor == 1 && sent_anchor == 4);
    context.composition_active = 1;
    preedit_string(self, self->handle, "provisional", 11, 11);
    done(self, self->handle, self->serial);
    telar_text_input_update(self);
    unsigned prior = commits;
    uint32_t old_serial = self->serial;
    context.composition_active = 0;
    context_pending = true;
    telar_text_input_update(self);
    assert(commits == prior && self->published.composition_active == 1);
    context_pending = false;
    telar_text_input_update(self);
    assert(commits == prior + 2 && self->published.composition_active == 0);
    event_count = 0;
    commit_string(self, self->handle, "cancelled");
    done(self, self->handle, old_serial);
    assert(event_count == 0); // Same widget generation, retired composition session.
    preedit_string(self, self->handle, "cancelled together", 18, 18);
    done(self, self->handle, self->serial);
    assert(self->composing && self->published.composition_active == 0);
    prior = commits;
    telar_text_input_update(self);
    assert(commits == prior + 2 && !self->composing); // Zig consumed preedit and a cancelling click in the same pump.
    unsigned prior_surrounding = surrounding_calls;
    context.text = (const uint8_t *)"a\0b";
    context.len = 3;
    context.selection_start = context.selection_end = 3;
    telar_text_input_update(self);
    assert(!self->enabled && surrounding_calls == prior_surrounding); // Wayland strings cannot carry embedded NUL.
    self->seat = (void *)1;
    telar_text_input_destroy(self);
    assert(!proxy.alive);
    puts("Wayland IME: buffered composition, atomic replacement, serial identity, caret, UTF-8 bounds and focus passed");
    return 0;
}
