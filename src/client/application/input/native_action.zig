//! Application preflight for one source-independent native action.

const NativeActionCapture = @import("NativeActionCapture.zig");
const NativeActionHandler = @import("NativeActionHandler.zig");
const action_module = @import("../../input/action.zig");
const std = @import("std");
const action_routing = @import("action_routing.zig");

pub const Event = enum {
    leave_copy_mode,
    deliver,
};

pub const Failure = enum {
    none,
    leave_copy_mode,
    deliver,
};

test "NativeActionHandler retires active copy mode before native delivery" {
    var capture: NativeActionCapture = .{ .control = .stop };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };
    const action = action_module.Action.detach;

    try std.testing.expectEqual(
        action_routing.Control.stop,
        try handler.execute(action, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(action, capture.delivered.?);
}

test "NativeActionHandler preserves copy mode for entry and inactive state" {
    var capture: NativeActionCapture = .{};
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(
        action_routing.Control.continue_routing,
        try handler.execute(.enter_copy_mode, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());

    capture = .{};
    handler = .{ .effects = capture.effects() };
    _ = try handler.execute(.toggle_sidebar, .{ .copy_mode_active = false });
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());
}

test "NativeActionHandler stops before delivery when copy-mode retirement fails" {
    var capture: NativeActionCapture = .{ .failure = .leave_copy_mode };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.CopyModeLeaveFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{.leave_copy_mode}, capture.eventSlice());
    try std.testing.expect(capture.delivered == null);
}

test "NativeActionHandler retains completed preflight when delivery fails" {
    var capture: NativeActionCapture = .{ .failure = .deliver };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.NativeActionDeliveryFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(action_module.Action.toggle_sidebar, capture.delivered.?);
}
