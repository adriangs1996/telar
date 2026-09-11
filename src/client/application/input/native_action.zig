//! Application preflight for one source-independent native action.

const std = @import("std");
const input = @import("../../input/root.zig");
const action_routing = @import("action_routing.zig");

pub const Action = input.action.Action;

pub const Authority = @import("NativeActionAuthority.zig");

pub const Control = action_routing.Control;

pub const Effects = @import("NativeActionEffects.zig");

pub const NativeActionHandler = @import("NativeActionHandler.zig");

pub const Event = enum {
    leave_copy_mode,
    deliver,
};

pub const Failure = enum {
    none,
    leave_copy_mode,
    deliver,
};

const Capture = @import("NativeActionCapture.zig");

test "NativeActionHandler retires active copy mode before native delivery" {
    var capture: Capture = .{ .control = .stop };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };
    const action = Action.detach;

    try std.testing.expectEqual(
        Control.stop,
        try handler.execute(action, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(action, capture.delivered.?);
}

test "NativeActionHandler preserves copy mode for entry and inactive state" {
    var capture: Capture = .{};
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.enter_copy_mode, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());

    capture = .{};
    handler = .{ .effects = capture.effects() };
    _ = try handler.execute(.toggle_sidebar, .{ .copy_mode_active = false });
    try std.testing.expectEqualSlices(Event, &.{.deliver}, capture.eventSlice());
}

test "NativeActionHandler stops before delivery when copy-mode retirement fails" {
    var capture: Capture = .{ .failure = .leave_copy_mode };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.CopyModeLeaveFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{.leave_copy_mode}, capture.eventSlice());
    try std.testing.expect(capture.delivered == null);
}

test "NativeActionHandler retains completed preflight when delivery fails" {
    var capture: Capture = .{ .failure = .deliver };
    var handler: NativeActionHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.NativeActionDeliveryFailed,
        handler.execute(.toggle_sidebar, .{ .copy_mode_active = true }),
    );

    try std.testing.expectEqualSlices(Event, &.{ .leave_copy_mode, .deliver }, capture.eventSlice());
    try std.testing.expectEqualDeep(Action.toggle_sidebar, capture.delivered.?);
}
