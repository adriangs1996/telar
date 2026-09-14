#define _POSIX_C_SOURCE 200809L
#include "text_input.h"
#include "text-input-unstable-v3-client-protocol.h"
#include <limits.h>
#include <glib.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SERIAL_HISTORY 32
#define SURROUNDING_LIMIT 4000

struct text_serial {
    uint32_t serial, epoch;
    uint64_t target_id, generation;
    uint32_t cursor, anchor, len;
    bool valid;
};

struct telar_text_input {
    void *context;
    telar_gui_callbacks callbacks;
    struct zwp_text_input_manager_v3 *manager;
    struct zwp_text_input_v3 *handle;
    struct wl_seat *seat;
    uint32_t manager_global, serial, epoch;
    bool entered, enabled, desynchronized, composing, invalid;
    telar_gui_text_context published;
    uint8_t surrounding[TELAR_GUI_TEXT_CAPACITY + 1];
    struct text_serial history[SERIAL_HISTORY];
    char preedit[TELAR_GUI_TEXT_CAPACITY + 1], committed[TELAR_GUI_TEXT_CAPACITY + 1];
    uint8_t expected[TELAR_GUI_TEXT_CAPACITY + 1];
    size_t expected_len;
    uint32_t expected_cursor;
    bool expected_valid;
    uint32_t before, after;
    int32_t cursor_begin, cursor_end;
};

static bool boundary(const uint8_t *text, size_t len, uint32_t offset) {
    return offset <= len && (offset == len || (text[offset] & 0xc0) != 0x80);
}

static void reset_pending(telar_text_input *self) {
    self->preedit[0] = self->committed[0] = 0;
    self->before = self->after = 0;
    self->cursor_begin = self->cursor_end = 0;
    self->invalid = false;
}

static telar_gui_input event_for(const struct text_serial *state, uint32_t kind) {
    return (telar_gui_input){.kind = kind, .phase = 1, .target_id = state->target_id, .generation = state->generation,
        .replacement_start = TELAR_GUI_RANGE_NONE, .replacement_end = TELAR_GUI_RANGE_NONE};
}

static void cancel(telar_text_input *self) {
    if (self->composing) {
        telar_gui_input event = {.kind = 7, .code = 2, .target_id = self->published.target_id, .generation = self->published.generation};
        self->callbacks.input(self->context, event);
    }
    self->composing = false;
    reset_pending(self);
}

static void commit_state(telar_text_input *self) {
    zwp_text_input_v3_commit(self->handle);
    self->serial++;
    self->history[self->serial % SERIAL_HISTORY] = (struct text_serial){.serial = self->serial, .epoch = self->epoch, .valid = true,
        .target_id = self->published.target_id, .generation = self->published.generation,
        .cursor = self->published.selection_end, .anchor = self->published.selection_start, .len = (uint32_t)self->published.len};
}

static void enter(void *data, struct zwp_text_input_v3 *handle, struct wl_surface *surface) {
    (void)handle; (void)surface;
    telar_text_input *self = data;
    self->epoch++;
    self->entered = true;
    self->enabled = self->desynchronized = false;
    telar_text_input_update(self);
}

static void leave(void *data, struct zwp_text_input_v3 *handle, struct wl_surface *surface) {
    (void)handle; (void)surface;
    telar_text_input *self = data;
    cancel(self);
    self->entered = self->enabled = false;
    self->desynchronized = false;
}

static bool copy_text(char *destination, const char *text) {
    if (text == NULL) text = "";
    size_t len = strnlen(text, TELAR_GUI_TEXT_CAPACITY + 1);
    if (len > TELAR_GUI_TEXT_CAPACITY) return false;
    memcpy(destination, text, len + 1);
    return true;
}

static void preedit_string(void *data, struct zwp_text_input_v3 *handle, const char *text, int32_t begin, int32_t end) {
    (void)handle;
    telar_text_input *self = data;
    if (!copy_text(self->preedit, text)) {
        self->invalid = true;
        return;
    }
    size_t len = strlen(self->preedit);
    if (!((begin == -1 && end == -1) || (begin >= 0 && end >= 0 && boundary((const uint8_t *)self->preedit, len, (uint32_t)begin) && boundary((const uint8_t *)self->preedit, len, (uint32_t)end)))) {
        self->invalid = true;
    }
    self->cursor_begin = begin;
    self->cursor_end = end;
}

static void commit_string(void *data, struct zwp_text_input_v3 *handle, const char *text) {
    (void)handle;
    telar_text_input *self = data;
    if (!copy_text(self->committed, text)) self->invalid = true;
}

static void delete_surrounding(void *data, struct zwp_text_input_v3 *handle, uint32_t before, uint32_t after) {
    (void)handle;
    telar_text_input *self = data;
    self->before = before;
    self->after = after;
}

static void done(void *data, struct zwp_text_input_v3 *handle, uint32_t serial) {
    (void)handle;
    telar_text_input *self = data;
    const struct text_serial state = self->history[serial % SERIAL_HISTORY];
    if (state.valid && state.serial == serial && state.epoch != self->epoch) {
        reset_pending(self);
        return;
    }
    self->desynchronized = serial != self->serial;
    if (!self->entered || !self->enabled || self->invalid || !state.valid || state.serial != serial) {
        reset_pending(self);
        return;
    }

    uint32_t low = state.cursor < state.anchor ? state.cursor : state.anchor;
    uint32_t high = state.cursor > state.anchor ? state.cursor : state.anchor;
    if (self->before > low || self->after > state.len - high) {
        reset_pending(self);
        return;
    }

    size_t committed_len = strlen(self->committed);
    if (committed_len > 0 || self->before > 0 || self->after > 0) {
        // One replacement admits deletion and commit together; queue saturation
        // cannot delete surrounding text while dropping the inserted text.
        telar_gui_input event = event_for(&state, 1);
        event.text = (const uint8_t *)self->committed;
        event.len = committed_len;
        event.replacement_start = low - self->before;
        event.replacement_end = high + self->after;
        if (!self->callbacks.input(self->context, event)) {
            reset_pending(self);
            return;
        }
        self->expected_valid = false;
        size_t prefix = event.replacement_start, suffix = state.len - event.replacement_end;
        if (serial == self->serial && prefix + committed_len + suffix <= TELAR_GUI_TEXT_CAPACITY) {
            memcpy(self->expected, self->surrounding, prefix);
            memcpy(self->expected + prefix, self->committed, committed_len);
            memcpy(self->expected + prefix + committed_len, self->surrounding + event.replacement_end, suffix);
            self->expected_len = prefix + committed_len + suffix;
            self->expected_cursor = (uint32_t)(prefix + committed_len);
            self->expected_valid = true;
        }
    }

    size_t preedit_len = strlen(self->preedit);
    if (preedit_len > 0 || self->composing) {
        telar_gui_input event = event_for(&state, 7);
        event.code = preedit_len > 0 ? 1 : 2;
        event.text = (const uint8_t *)self->preedit;
        event.len = preedit_len;
        event.selection_start = self->cursor_begin < 0 ? 0 : (uint32_t)self->cursor_begin;
        event.selection_end = self->cursor_end < 0 ? 0 : (uint32_t)self->cursor_end;
        if (self->callbacks.input(self->context, event)) self->composing = preedit_len > 0;
    }
    reset_pending(self);
}

static const struct zwp_text_input_v3_listener listener = {
    .enter = enter, .leave = leave, .preedit_string = preedit_string,
    .commit_string = commit_string, .delete_surrounding_text = delete_surrounding, .done = done,
};

static void ensure_handle(telar_text_input *self) {
    if (self->manager != NULL && self->seat != NULL && self->handle == NULL) {
        self->handle = zwp_text_input_manager_v3_get_text_input(self->manager, self->seat);
        if (self->handle != NULL) zwp_text_input_v3_add_listener(self->handle, &listener, self);
    }
}

telar_text_input *telar_text_input_create(void *context, const telar_gui_callbacks *callbacks) {
    telar_text_input *self = calloc(1, sizeof *self);
    if (self != NULL) {
        self->context = context;
        self->callbacks = *callbacks;
    }
    return self;
}

void telar_text_input_global(telar_text_input *self, const telar_registry_global *global) {
    if (self->manager == NULL && !strcmp(global->interface, zwp_text_input_manager_v3_interface.name)) {
        self->manager = wl_registry_bind(global->registry, global->name, &zwp_text_input_manager_v3_interface, 1);
        self->manager_global = global->name;
        ensure_handle(self);
    }
}

void telar_text_input_seat(telar_text_input *self, struct wl_seat *seat) {
    if (self->seat == seat) return;
    cancel(self);
    if (self->handle != NULL) zwp_text_input_v3_destroy(self->handle);
    self->handle = NULL;
    self->seat = seat;
    self->enabled = self->entered = self->desynchronized = false;
    self->serial = 0;
    memset(self->history, 0, sizeof self->history);
    ensure_handle(self);
}

void telar_text_input_remove(telar_text_input *self, uint32_t name) {
    if (self->manager != NULL && self->manager_global == name) {
        struct wl_seat *seat = self->seat;
        telar_text_input_seat(self, NULL);
        zwp_text_input_manager_v3_destroy(self->manager);
        self->manager = NULL;
        self->seat = seat;
    }
}

static int32_t coordinate(double value) {
    return (int32_t)fmax(INT32_MIN, fmin(INT32_MAX, floor(value)));
}

void telar_text_input_update(telar_text_input *self) {
    if (self->handle == NULL || !self->entered) return;
    telar_gui_text_context next = {0};
    if (self->callbacks.text_context != NULL && self->callbacks.text_context(self->context, &next) < 0) return;
    if (next.len > TELAR_GUI_TEXT_CAPACITY || (next.len > 0 && (next.text == NULL || !g_utf8_validate((const char *)next.text, (gssize)next.len, NULL))) || !boundary(next.text, next.len, next.selection_start) || !boundary(next.text, next.len, next.selection_end) || !isfinite(next.x) || !isfinite(next.y) || !isfinite(next.width) || !isfinite(next.height)) next.enabled = 0;
    bool changed_target = self->published.target_id != next.target_id || self->published.generation != next.generation;
    bool reset_composition = self->composing && !next.composition_active;
    if (self->enabled && (!next.enabled || changed_target || reset_composition)) {
        cancel(self);
        zwp_text_input_v3_disable(self->handle);
        commit_state(self);
        self->epoch++;
        self->enabled = false;
        self->desynchronized = false;
    }
    if (!next.enabled || self->desynchronized) return;
    bool surrounding_changed = changed_target || next.len != self->published.len || next.selection_start != self->published.selection_start || next.selection_end != self->published.selection_end || (next.len != 0 && memcmp(next.text, self->surrounding, next.len) != 0);
    bool changed = !self->enabled || surrounding_changed || next.revision != self->published.revision || next.composition_active != self->published.composition_active || next.x != self->published.x || next.y != self->published.y || next.width != self->published.width || next.height != self->published.height;
    if (!changed) return;
    if (!self->enabled) {
        zwp_text_input_v3_enable(self->handle);
        zwp_text_input_v3_set_content_type(self->handle, ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    }
    if (surrounding_changed) {
        bool from_ime = self->expected_valid && !changed_target && next.len == self->expected_len && next.selection_start == self->expected_cursor && next.selection_end == self->expected_cursor && (next.len == 0 || memcmp(next.text, self->expected, next.len) == 0);
        zwp_text_input_v3_set_text_change_cause(self->handle, from_ime ? ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD : ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
        self->expected_valid = false;
    }
    self->published = next;
    if (next.len != 0) memcpy(self->surrounding, next.text, next.len);
    self->surrounding[next.len] = 0;
    self->published.text = self->surrounding;
    uint32_t low = next.selection_start < next.selection_end ? next.selection_start : next.selection_end;
    uint32_t high = next.selection_start > next.selection_end ? next.selection_start : next.selection_end;
    if (high - low <= SURROUNDING_LIMIT) {
        uint32_t start = high > SURROUNDING_LIMIT ? high - SURROUNDING_LIMIT : 0;
        while (start < low && !boundary(self->surrounding, next.len, start)) start++;
        uint32_t end = next.len - start > SURROUNDING_LIMIT ? start + SURROUNDING_LIMIT : (uint32_t)next.len;
        while (end > high && !boundary(self->surrounding, next.len, end)) end--;
        uint8_t saved = self->surrounding[end];
        self->surrounding[end] = 0;
        zwp_text_input_v3_set_surrounding_text(self->handle, (const char *)self->surrounding + start, (int32_t)(next.selection_end - start), (int32_t)(next.selection_start - start));
        self->surrounding[end] = saved;
    }
    zwp_text_input_v3_set_cursor_rectangle(self->handle, coordinate(next.x), coordinate(next.y), coordinate(fmax(1, next.width)), coordinate(fmax(1, next.height)));
    commit_state(self);
    self->enabled = true;
}

void telar_text_input_destroy(telar_text_input *self) {
    if (self == NULL) return;
    telar_text_input_seat(self, NULL);
    if (self->manager != NULL) zwp_text_input_manager_v3_destroy(self->manager);
    free(self);
}
