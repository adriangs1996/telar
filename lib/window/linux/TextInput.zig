const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const HostState = @import("../HostState.zig");
const raw_input = @import("../input/NativeInput.zig");
const RawInput = raw_input.NativeInput;
const TextInput = @This();
const capacity = c.TELAR_GUI_TEXT_CAPACITY;
const serial_capacity = 32;
const surrounding_limit = 4000;
const Serial = struct {
    serial: u32 = 0,
    epoch: u32 = 0,
    target_id: u64 = 0,
    generation: u64 = 0,
    cursor: u32 = 0,
    anchor: u32 = 0,
    len: u32 = 0,
    valid: bool = false,
};

host: *HostState,
manager: ?*c.zwp_text_input_manager_v3 = null,
handle: ?*c.zwp_text_input_v3 = null,
seat: ?*c.wl_seat = null,
manager_global: u32 = 0,
serial: u32 = 0,
epoch: u32 = 0,
entered: bool = false,
enabled: bool = false,
desynchronized: bool = false,
composing: bool = false,
invalid: bool = false,
published: c.telar_gui_text_context = std.mem.zeroes(c.telar_gui_text_context),
surrounding: [capacity + 1]u8 = @splat(0),
history: [serial_capacity]Serial = @splat(.{}),
preedit: [capacity + 1]u8 = @splat(0),
committed: [capacity + 1]u8 = @splat(0),
// SAFETY: The IME commit path fills the expected prefix before setting expected_valid; comparison also checks expected_len.
expected: [capacity]u8 = undefined,
expected_len: usize = 0,
expected_cursor: u32 = 0,
expected_valid: bool = false,
before: u32 = 0,
after: u32 = 0,
cursor_begin: i32 = 0,
cursor_end: i32 = 0,

pub fn boundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}

fn reset(self: *TextInput) void {
    self.preedit[0] = 0;
    self.committed[0] = 0;
    self.before = 0;
    self.after = 0;
    self.cursor_begin = 0;
    self.cursor_end = 0;
    self.invalid = false;
}

fn emit(self: *TextInput, event: RawInput) bool {
    return self.host.receive(@bitCast(event));
}

fn cancel(self: *TextInput) void {
    if (self.composing) {
        _ = self.emit(.{ .kind = 7, .code = 2, .target_id = self.published.target_id, .generation = self.published.generation });
    }
    self.composing = false;
    self.reset();
}

fn commit(self: *TextInput) void {
    c.zwp_text_input_v3_commit(self.handle);
    self.serial +%= 1;
    self.history[self.serial % serial_capacity] = .{
        .serial = self.serial,
        .epoch = self.epoch,
        .valid = true,
        .target_id = self.published.target_id,
        .generation = self.published.generation,
        .cursor = self.published.selection_end,
        .anchor = self.published.selection_start,
        .len = @intCast(self.published.len),
    };
}

fn from(data: ?*anyopaque) *TextInput {
    return @ptrCast(@alignCast(data.?));
}

/// text-input-v3 focus starts a new serial epoch; replies from a previous focus
/// cannot edit the newly focused target, even if it shares the same protocol object.
fn enter(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, _: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    self.epoch +%= 1;
    self.entered = true;
    self.enabled = false;
    self.desynchronized = false;
    self.publish();
}

fn leave(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, _: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    self.cancel();
    self.entered = false;
    self.enabled = false;
    self.desynchronized = false;
}

fn copy(destination: *[capacity + 1]u8, source: [*c]const u8) bool {
    const len = if (source == null) 0 else c.strnlen(source, destination.len);
    if (len > capacity) {
        return false;
    }
    if (len != 0) {
        @memcpy(destination[0..len], source[0..len]);
    }
    destination[len] = 0;
    return true;
}

fn preeditString(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, text: [*c]const u8, begin: i32, end: i32) callconv(.c) void {
    const self = from(data);
    if (!copy(&self.preedit, text)) {
        self.invalid = true;
        return;
    }
    const bytes = std.mem.sliceTo(&self.preedit, 0);
    if (!((begin == -1 and end == -1) or (begin >= 0 and end >= 0 and boundary(bytes, @intCast(begin)) and boundary(bytes, @intCast(end))))) {
        self.invalid = true;
    }
    self.cursor_begin = begin;
    self.cursor_end = end;
}

fn commitString(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, text: [*c]const u8) callconv(.c) void {
    const self = from(data);
    if (!copy(&self.committed, text)) {
        self.invalid = true;
    }
}

fn deleteSurrounding(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, before: u32, after: u32) callconv(.c) void {
    const self = from(data);
    self.before = before;
    self.after = after;
}

/// A done message seals an IME transaction. Deletion and commit become one
/// replacement, so queue pressure cannot admit deletion without the inserted text.
fn done(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, serial: u32) callconv(.c) void {
    const self = from(data);
    defer self.reset();
    const previous = self.history[serial % serial_capacity];
    if (previous.valid and previous.serial == serial and previous.epoch != self.epoch) {
        return;
    }
    self.desynchronized = serial != self.serial;
    if (!self.entered or !self.enabled or self.invalid or !previous.valid or previous.serial != serial) {
        return;
    }
    const low = @min(previous.cursor, previous.anchor);
    const high = @max(previous.cursor, previous.anchor);
    if (self.before > low or self.after > previous.len - high) {
        return;
    }
    const committed = std.mem.sliceTo(&self.committed, 0);
    if (committed.len != 0 or self.before != 0 or self.after != 0) {
        const event: RawInput = .{
            .kind = 1,
            .target_id = previous.target_id,
            .generation = previous.generation,
            .text = committed.ptr,
            .len = committed.len,
            .replacement_start = low - self.before,
            .replacement_end = high + self.after,
        };
        if (!self.emit(event)) {
            return;
        }
        self.expected_valid = false;
        const prefix = event.replacement_start;
        const suffix = previous.len - event.replacement_end;
        if (serial == self.serial and prefix + committed.len + suffix <= capacity) {
            @memcpy(self.expected[0..prefix], self.surrounding[0..prefix]);
            @memcpy(self.expected[prefix..][0..committed.len], committed);
            @memcpy(self.expected[prefix + committed.len ..][0..suffix], self.surrounding[event.replacement_end..][0..suffix]);
            self.expected_len = prefix + committed.len + suffix;
            self.expected_cursor = @intCast(prefix + committed.len);
            self.expected_valid = true;
        }
    }
    const preedit = std.mem.sliceTo(&self.preedit, 0);
    if (preedit.len != 0 or self.composing) {
        if (self.emit(.{
            .kind = 7,
            .code = if (preedit.len != 0) 1 else 2,
            .target_id = previous.target_id,
            .generation = previous.generation,
            .text = preedit.ptr,
            .len = preedit.len,
            .selection_start = @intCast(@max(0, self.cursor_begin)),
            .selection_end = @intCast(@max(0, self.cursor_end)),
        })) {
            self.composing = preedit.len != 0;
        }
    }
}

const listener: c.zwp_text_input_v3_listener = .{
    .enter = enter,
    .leave = leave,
    .preedit_string = preeditString,
    .commit_string = commitString,
    .delete_surrounding_text = deleteSurrounding,
    .done = done,
};

fn bind(self: *TextInput) void {
    if (self.manager != null and self.seat != null and self.handle == null) {
        self.handle = c.zwp_text_input_manager_v3_get_text_input(self.manager, self.seat);
        if (self.handle) |handle| {
            _ = c.zwp_text_input_v3_add_listener(handle, &listener, self);
        }
    }
}

pub fn global(self: *TextInput, value: *const c.telar_registry_global) void {
    if (self.manager == null and std.mem.eql(u8, std.mem.span(value.interface), "zwp_text_input_manager_v3")) {
        self.manager = @ptrCast(c.wl_registry_bind(value.registry, value.name, &c.zwp_text_input_manager_v3_interface, 1));
        self.manager_global = value.name;
        self.bind();
    }
}

pub fn setSeat(self: *TextInput, seat: ?*c.wl_seat) void {
    if (self.seat == seat) {
        return;
    }
    self.cancel();
    if (self.handle) |handle| {
        c.zwp_text_input_v3_destroy(handle);
    }
    self.handle = null;
    self.seat = seat;
    self.entered = false;
    self.enabled = false;
    self.desynchronized = false;
    self.serial = 0;
    self.history = @splat(.{});
    self.bind();
}

pub fn remove(self: *TextInput, name: u32) void {
    if (self.manager != null and self.manager_global == name) {
        const seat = self.seat;
        self.setSeat(null);
        c.zwp_text_input_manager_v3_destroy(self.manager);
        self.manager = null;
        self.seat = seat;
    }
}

fn coordinate(value: f64) i32 {
    return @intFromFloat(std.math.clamp(@floor(value), std.math.minInt(i32), std.math.maxInt(i32)));
}

/// Publishes the window's owned editing snapshot directly. Pending input keeps
/// the native optimistic mirror until the GUI consumes it and publishes its update.
pub fn publish(self: *TextInput) void {
    if (self.handle == null or !self.entered or self.host.inputs.len != 0) {
        return;
    }
    var next = self.host.text;
    const bytes = if (next.len == 0) "" else next.text[0..next.len];
    if (!boundary(bytes, next.selection_start) or !boundary(bytes, next.selection_end)) {
        next.enabled = 0;
    }
    const target_changed = self.published.target_id != next.target_id or self.published.generation != next.generation;
    const reset_composition = self.composing and next.composition_active == 0;
    if (self.enabled and (next.enabled == 0 or target_changed or reset_composition)) {
        self.cancel();
        c.zwp_text_input_v3_disable(self.handle);
        self.commit();
        self.epoch +%= 1;
        self.enabled = false;
        self.desynchronized = false;
    }
    if (next.enabled == 0 or self.desynchronized) {
        return;
    }
    const surrounding_changed = target_changed or next.len != self.published.len or next.selection_start != self.published.selection_start or next.selection_end != self.published.selection_end or !std.mem.eql(u8, bytes, self.surrounding[0..next.len]);
    const changed = !self.enabled or surrounding_changed or next.revision != self.published.revision or next.composition_active != self.published.composition_active or next.x != self.published.x or next.y != self.published.y or next.width != self.published.width or next.height != self.published.height;
    if (!changed) {
        return;
    }
    if (!self.enabled) {
        c.zwp_text_input_v3_enable(self.handle);
        c.zwp_text_input_v3_set_content_type(self.handle, c.ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, c.ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    }
    if (surrounding_changed) {
        const from_ime = self.expected_valid and !target_changed and next.len == self.expected_len and next.selection_start == self.expected_cursor and next.selection_end == self.expected_cursor and std.mem.eql(u8, bytes, self.expected[0..next.len]);
        c.zwp_text_input_v3_set_text_change_cause(self.handle, if (from_ime) c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD else c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
        self.expected_valid = false;
    }
    self.published = next;
    @memcpy(self.surrounding[0..next.len], bytes);
    self.surrounding[next.len] = 0;
    self.published.text = &self.surrounding;
    const low = @min(next.selection_start, next.selection_end);
    const high = @max(next.selection_start, next.selection_end);
    if (high - low <= surrounding_limit) {
        var start = high -| surrounding_limit;
        while (start < low and !boundary(bytes, start)) : (start += 1) {}
        var end = @min(next.len, start + surrounding_limit);
        while (end > high and !boundary(bytes, end)) : (end -= 1) {}
        const saved = self.surrounding[end];
        self.surrounding[end] = 0;
        c.zwp_text_input_v3_set_surrounding_text(self.handle, self.surrounding[start..].ptr, @intCast(next.selection_end - start), @intCast(next.selection_start - start));
        self.surrounding[end] = saved;
    }
    c.zwp_text_input_v3_set_cursor_rectangle(self.handle, coordinate(next.x), coordinate(next.y), coordinate(@max(1, next.width)), coordinate(@max(1, next.height)));
    self.commit();
    self.enabled = true;
}

pub fn deinit(self: *TextInput) void {
    self.setSeat(null);
    if (self.manager) |manager| {
        c.zwp_text_input_manager_v3_destroy(manager);
    }
}

extern "c" fn telar_test_text_handle() *c.zwp_text_input_v3;
extern "c" fn telar_test_text_state(commits: c_uint, enables: c_uint, disables: c_uint, text: [*:0]const u8, cursor: i32) void;
extern "c" fn telar_test_text_rectangle() void;
