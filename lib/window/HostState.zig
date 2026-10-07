const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const EventBuffer = @import("input/EventBuffer.zig");
const input = @import("input/Input.zig");
const NativeInput = @import("input/NativeInput.zig");
const Viewport = @import("Viewport.zig");
const event = @import("Event.zig");
const HostState = @This();
const label_capacity = 512;

inputs: EventBuffer = .{},
viewport: ?Viewport = null,
resize_pending: bool = false,
interval: u64 = 0,
interval_pending: bool = false,
wake_pending: bool = false,
deadline_ns: ?u64 = null,
pointer: u32 = 0,
text: c.telar_gui_text_context = std.mem.zeroes(c.telar_gui_text_context),
// SAFETY: setTextContext copies validated bytes before publishing the text mirror; callbacks read only text.len bytes.
text_bytes: [c.TELAR_GUI_TEXT_CAPACITY]u8 = undefined,
request: ?c.telar_gui_host_request = null,
// SAFETY: requestHost copies the request bytes before publishing request; the native service uses only its recorded len.
request_bytes: [c.TELAR_GUI_CLIPBOARD_CAPACITY]u8 = undefined,
tree: c.telar_gui_accessibility_tree = std.mem.zeroes(c.telar_gui_accessibility_tree),
// SAFETY: setAccessibility fills every published node before replacing tree; consumers use only tree.count nodes.
nodes: [c.TELAR_GUI_ACCESSIBILITY_CAPACITY]c.telar_gui_accessibility_node = undefined,
// SAFETY: setAccessibility copies each node's label before publishing tree; native readers use only the node's label_len.
labels: [c.TELAR_GUI_ACCESSIBILITY_CAPACITY][label_capacity]u8 = undefined,
// SAFETY: setAccessibility copies each node's value before publishing tree; native readers use only the node's value_len.
values: [c.TELAR_GUI_ACCESSIBILITY_CAPACITY][c.TELAR_GUI_TEXT_CAPACITY]u8 = undefined,

/// Retire only at the next public event call. Text in the last returned input
/// remains borrowed while the caller updates its model and host snapshots.
pub fn next(self: *HostState) !?event.Event {
    if (self.inputs.next()) |value| {
        return .{ .input = value };
    }

    if (self.inputs.failure) |failure| {
        self.inputs.failure = null;
        return failure;
    }

    if (self.resize_pending) {
        self.resize_pending = false;
        return .{ .resize = self.viewport.? };
    }

    if (self.interval_pending) {
        self.interval_pending = false;
        return .{ .display_interval = self.interval };
    }

    if (self.wake_pending) {
        self.wake_pending = false;
        return .wake;
    }

    if (self.deadline_ns) |deadline| {
        if (try now() >= deadline) {
            self.deadline_ns = null;
            return .wake;
        }
    }

    return null;
}

/// Matches the existing one-shot client wake: zero disarms, a positive delay
/// schedules one wake using monotonic time. No timer polls an idle client.
pub fn wakeAfter(self: *HostState, delay_ms: u32) !void {
    self.deadline_ns = if (delay_ms == 0) null else try now() + @as(u64, delay_ms) * std.time.ns_per_ms;
}

pub fn timeout(self: *const HostState) !c_int {
    const deadline = self.deadline_ns orelse return -1;
    const remaining = deadline -| try now();
    return @intCast(@min(std.math.maxInt(c_int), (remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
}

fn now() !u64 {
    // SAFETY: clock_gettime writes time on success; failure returns before either field is read.
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) {
        return error.ClockUnavailable;
    }

    return @as(u64, @intCast(time.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(time.tv_nsec));
}

/// Own a bounded copy; later native callbacks may read it after GUI update has
/// replaced its original bytes. Native IME keeps its mirror while input is queued.
pub fn setTextContext(self: *HostState, value: c.telar_gui_text_context) !void {
    const bytes = try checkedBytes(value.text, value.len, self.text_bytes.len);
    if (value.selection_start > bytes.len or value.selection_end > bytes.len or !std.math.isFinite(value.x) or !std.math.isFinite(value.y) or !std.math.isFinite(value.width) or !std.math.isFinite(value.height)) {
        return error.InvalidTextContext;
    }

    @memcpy(self.text_bytes[0..bytes.len], bytes);
    self.text = value;
    self.text.text = &self.text_bytes;
}

/// One pending request in addition to the native service's in-flight operation.
/// Native code copies these bytes before taking another request. Capacity failure
/// leaves the caller's request unconsumed and does not truncate clipboard text.
pub fn requestHost(self: *HostState, value: c.telar_gui_host_request) !void {
    if (self.request != null) {
        return error.HostRequestsFull;
    }

    if (value.request_id == 0 or value.kind < 1 or value.kind > 3) {
        return error.InvalidHostRequest;
    }

    const bytes = try checkedBytes(value.text, value.len, self.request_bytes.len);
    @memcpy(self.request_bytes[0..bytes.len], bytes);
    var owned = value;
    owned.text = &self.request_bytes;
    self.request = owned;
}

/// Validate the entire snapshot before replacing it. The native accessibility
/// adapters copy nodes on their own threads/services; no GUI pointers escape.
pub fn setAccessibility(self: *HostState, tree: c.telar_gui_accessibility_tree) !void {
    if (tree.count > self.nodes.len or (tree.count != 0 and tree.nodes == null)) {
        return error.InputTooLarge;
    }

    for ((if (tree.count == 0) &[_]c.telar_gui_accessibility_node{} else tree.nodes[0..tree.count])) |node| {
        _ = try checkedBytes(node.label, node.label_len, label_capacity);
        _ = try checkedBytes(node.value, node.value_len, c.TELAR_GUI_TEXT_CAPACITY);
    }

    for ((if (tree.count == 0) &[_]c.telar_gui_accessibility_node{} else tree.nodes[0..tree.count]), 0..) |node, index| {
        self.nodes[index] = node;
        if (node.label_len != 0) {
            @memcpy(self.labels[index][0..node.label_len], node.label[0..node.label_len]);
        }

        if (node.value_len != 0) {
            @memcpy(self.values[index][0..node.value_len], node.value[0..node.value_len]);
        }

        self.nodes[index].label = &self.labels[index];
        self.nodes[index].value = &self.values[index];
    }

    self.tree = tree;
    self.tree.nodes = &self.nodes;
}

fn checkedBytes(pointer: [*c]const u8, len: usize, capacity: usize) ![]const u8 {
    if (len > capacity) {
        return error.InputTooLarge;
    }

    if (len == 0) {
        return "";
    }

    if (pointer == null or !std.unicode.utf8ValidateSlice(pointer[0..len])) {
        return error.InvalidUtf8;
    }

    return pointer[0..len];
}

pub fn receive(self: *HostState, raw: c.telar_gui_input) bool {
    const decoded = input.Input.fromNative(@as(NativeInput.NativeInput, @bitCast(raw))) catch |err| {
        self.inputs.failure = err;
        return false;
    };
    return self.inputs.append(decoded);
}

pub fn resize(self: *HostState, value: c.telar_gui_viewport) void {
    const viewport: Viewport = .{ .width = value.width, .height = value.height, .scale = value.scale, .controls = value.controls };
    if (self.viewport == null or !std.meta.eql(self.viewport.?, viewport)) {
        self.viewport = viewport;
        self.resize_pending = true;
    }
}

pub fn displayInterval(self: *HostState, interval: u64) void {
    if (interval != 0 and interval != self.interval) {
        self.interval = interval;
        self.interval_pending = true;
    }
}
