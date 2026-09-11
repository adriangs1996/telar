//! Application policy for keyboard copy mode and captured mouse selections.

const std = @import("std");
const Mouse = @import("../../input/root.zig").Mouse;
const core = @import("telar-core");
const copy_mode = @import("../../input/root.zig").copy_mode;

pub const Command = @import("CopyModePointerCommand.zig");

pub const Authority = union(enum) {
    unowned,
    target_missing,
    selection: struct {
        dragging: bool,
        position: ?core.ui.Point,
    },
    owned: struct {
        pointer_inside: bool,
    },
};

pub const Outcome = enum {
    unowned,
    consumed,
    moved,
    exited,
};

pub const Effects = @import("CopyModePointerEffects.zig");

pub const CopyModePointerHandler = @import("CopyModePointerHandler.zig");

pub const Event = enum {
    leave,
    vertical,
    pointer,
    cancel_pointer,
};

pub const Failure = enum {
    none,
    leave,
    vertical,
};

const EffectsCapture = @import("CopyModePointerEffectsCapture.zig");

test "mouse selection consumes unrelated buttons and clips through resolved pane coordinates" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };
    const authority: Authority = .{ .selection = .{ .dragging = true, .position = .{ .x = 0, .y = 9 } } };
    try std.testing.expectEqual(Outcome.consumed, try handler.execute(.{ .kind = .release, .left_button = false }, authority));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(Outcome.moved, try handler.execute(.{ .kind = .release }, authority));
    try std.testing.expectEqualDeep(copy_mode.PointerMotion{ .position = .{ .x = 0, .y = 9 }, .release = true }, capture.motion.?);
}

test "missing selection geometry cancels before releasing its physical gesture" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };
    const authority: Authority = .{ .selection = .{ .dragging = true, .position = null } };
    try std.testing.expectEqual(Outcome.consumed, try handler.execute(.{ .kind = .drag }, authority));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(Outcome.consumed, try handler.execute(.{ .kind = .release }, authority));
    try std.testing.expectEqualSlices(Event, &.{.cancel_pointer}, capture.events[0..capture.event_count]);
}

test "copy-mode pointer leaves unowned input for later routing" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(
        Outcome.unowned,
        try handler.execute(.{ .kind = .press }, .unowned),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "copy-mode pointer consumes non-wheel and outside-wheel input" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(
        Outcome.consumed,
        try handler.execute(.{ .kind = .press }, .{ .owned = .{ .pointer_inside = true } }),
    );
    try std.testing.expectEqual(
        Outcome.consumed,
        try handler.execute(.{ .kind = .scroll_up }, .{ .owned = .{ .pointer_inside = false } }),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "copy-mode pointer moves three rows for each inside wheel direction" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };
    const authority: Authority = .{ .owned = .{ .pointer_inside = true } };

    try std.testing.expectEqual(Outcome.moved, try handler.execute(.{ .kind = .scroll_up }, authority));
    try std.testing.expectEqualSlices(Event, &.{.vertical}, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(@as(i32, -3), capture.delta);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    try std.testing.expectEqual(Outcome.moved, try handler.execute(.{ .kind = .scroll_down }, authority));
    try std.testing.expectEqualSlices(Event, &.{.vertical}, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(@as(i32, 3), capture.delta);
}

test "copy-mode pointer exits a missing target and propagates selected failures" {
    var capture: EffectsCapture = .{};
    var handler: CopyModePointerHandler = .{ .effects = capture.effects() };
    const missing: Authority = .target_missing;

    try std.testing.expectEqual(Outcome.exited, try handler.execute(.{ .kind = .move }, missing));
    try std.testing.expectEqualSlices(Event, &.{.leave}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .leave };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(
        error.CopyModeLeaveFailed,
        handler.execute(.{ .kind = .move }, missing),
    );
    try std.testing.expectEqualSlices(Event, &.{.leave}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .vertical };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(
        error.CopyModeMovementFailed,
        handler.execute(.{ .kind = .scroll_up }, .{ .owned = .{ .pointer_inside = true } }),
    );
    try std.testing.expectEqualSlices(Event, &.{.vertical}, capture.events[0..capture.event_count]);
}
