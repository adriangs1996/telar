//! Bounded color-probe lifecycle for one exterior terminal. OSC reports have
//! no request ID, so probes never overlap and unsolicited reports are ignored.

const std = @import("std");
const deadline_timer = @import("deadline_timer.zig");

pub const timeout_ns = 250 * std.time.ns_per_ms;
pub const pixel_query = "\x1b[14t\x1b[16t";
pub const color_query = "\x1b]10;?\x07\x1b]11;?\x07";
pub const Color = enum { foreground, background };

pub const State = struct {
    zlib_support: @import("telar-client").environment.Support = .unknown,
    deadline_ns: ?u64 = null,
    received: std.EnumSet(Color) = .initEmpty(),
    initial_settled: bool = false,
    timer: deadline_timer.Scheduler = .{},

    /// Example: `if (state.begin(now_ns)) try writer.writeAll(color_query);`.
    pub fn begin(state: *State, now_ns: u64) bool {
        if (state.deadline_ns != null) {
            return false;
        }

        state.deadline_ns = now_ns +| timeout_ns;
        state.received = .initEmpty();
        return true;
    }

    /// Example: `if (!state.accept(.foreground, now_ns)) return;`.
    pub fn accept(state: *State, color: Color, now_ns: u64) bool {
        const deadline = state.deadline_ns orelse return false;
        if (now_ns >= deadline or state.received.contains(color)) {
            return false;
        }

        state.received.insert(color);
        if (state.received.count() == 2) {
            state.initial_settled = true;
        }

        return true;
    }

    /// Example: `if (state.expire(now_ns)) settleUnansweredCapabilities();`.
    pub fn expire(state: *State, now_ns: u64) bool {
        const deadline = state.deadline_ns orelse return false;
        if (now_ns < deadline) {
            return false;
        }

        state.deadline_ns = null;
        state.initial_settled = true;
        return true;
    }
};

/// Resolves unanswered terminal probes without putting probe policy in the model.
/// Example: `const next = settledCapabilities(current);`.
pub fn settledCapabilities(current: @import("telar-client").model.HostCapabilities) @import("telar-client").model.HostCapabilities {
    var next = current;
    if (next.images == .unknown) {
        next.images = .unsupported;
    }

    if (next.pointer_pixels == .unknown) {
        next.pointer_pixels = .unsupported;
    }

    return next;
}

test "probe fallback retains resolved capabilities" {
    const current: @import("telar-client").model.HostCapabilities = .{ .images = .supported, .appearance = .dark };
    const next = settledCapabilities(current);
    try std.testing.expectEqual(.supported, next.images);
    try std.testing.expectEqual(.unsupported, next.pointer_pixels);
    try std.testing.expectEqual(.dark, next.appearance);
    try std.testing.expectEqualDeep(next, settledCapabilities(next));
}

test "color probes settle independently of graphics and reject stale reports" {
    var state: State = .{};
    try std.testing.expect(!state.accept(.background, 0));
    try std.testing.expect(state.begin(0));
    try std.testing.expect(!state.begin(1));
    try std.testing.expect(state.accept(.background, 1));
    try std.testing.expect(!state.initial_settled);
    try std.testing.expect(!state.accept(.background, 2));
    try std.testing.expect(state.accept(.foreground, 2));
    try std.testing.expect(state.initial_settled);
    try std.testing.expect(!state.expire(3));
    try std.testing.expect(state.expire(timeout_ns));
    try std.testing.expect(!state.accept(.foreground, timeout_ns + 1));
    try std.testing.expect(state.begin(timeout_ns + 1));
}

test "missing color replies cannot hold startup beyond the deadline" {
    var state: State = .{};
    _ = state.begin(10);
    try std.testing.expect(!state.accept(.foreground, timeout_ns + 10));
    try std.testing.expect(state.expire(timeout_ns + 10));
    try std.testing.expect(state.initial_settled);
}
