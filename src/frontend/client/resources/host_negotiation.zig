//! Bounded color-probe lifecycle for one exterior terminal. OSC reports have
//! no request ID, so probes never overlap and unsolicited reports are ignored.

const std = @import("std");
const deadline_timer = @import("telar-client").resources.deadline_timer;

pub const timeout_ns = 250 * std.time.ns_per_ms;
pub const pixel_query = "\x1b[14t\x1b[16t";
pub const color_query = "\x1b]10;?\x07\x1b]11;?\x07";
pub const Color = enum { foreground, background };

pub const State = @import("HostNegotiationState.zig");

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
