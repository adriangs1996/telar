//! Application policy for keyboard copy mode and captured mouse selections.

const std = @import("std");
const Mouse = @import("../../input/root.zig").Mouse;
const core = @import("telar-core");
const copy_mode = @import("../../input/root.zig").copy_mode;

pub const Command = struct {
    kind: Mouse.Kind,
    left_button: bool = true,
};

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

pub const Effects = struct {
    context: *anyopaque,
    leave: *const fn (*anyopaque) anyerror!void,
    vertical: *const fn (*anyopaque, i32) anyerror!void,
    pointer: *const fn (*anyopaque, copy_mode.PointerMotion) anyerror!void,
    cancel_pointer: *const fn (*anyopaque) anyerror!void,
};

pub const CopyModePointerHandler = struct {
    effects: Effects,

    /// Routes captured selection gestures before chrome or child input.
    /// Keyboard copy mode consumes non-wheel events; its inside wheel moves
    /// the copy cursor. Missing mouse geometry cancels on release.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command, authority);
    /// ```
    pub fn execute(handler: *CopyModePointerHandler, command: Command, authority: Authority) !Outcome {
        const pointer_inside = switch (authority) {
            .unowned => return .unowned,
            .target_missing => {
                try handler.effects.leave(handler.effects.context);

                return .exited;
            },
            .selection => |selection| {
                if (selection.dragging and command.kind == .press and command.left_button) {
                    try handler.effects.cancel_pointer(handler.effects.context);

                    return .unowned;
                }

                if (!selection.dragging) {
                    if (command.kind == .press or command.kind == .scroll_up or command.kind == .scroll_down) {
                        try handler.effects.cancel_pointer(handler.effects.context);
                    }

                    return .unowned;
                }

                if (!command.left_button or (command.kind != .drag and command.kind != .release)) {
                    return .consumed;
                }

                const position = selection.position orelse {
                    if (command.kind == .release) {
                        try handler.effects.cancel_pointer(handler.effects.context);
                    }

                    return .consumed;
                };
                try handler.effects.pointer(handler.effects.context, .{
                    .position = position,
                    .release = command.kind == .release,
                });
                return .moved;
            },
            .owned => |owned| owned.pointer_inside,
        };

        const delta: i32 = switch (command.kind) {
            .scroll_up => -3,
            .scroll_down => 3,
            else => return .consumed,
        };

        if (!pointer_inside) {
            return .consumed;
        }

        try handler.effects.vertical(handler.effects.context, delta);
        return .moved;
    }
};

const Event = enum {
    leave,
    vertical,
    pointer,
    cancel_pointer,
};

const Failure = enum {
    none,
    leave,
    vertical,
};

const EffectsCapture = struct {
    events: [2]Event = undefined,
    event_count: usize = 0,
    delta: i32 = 0,
    failure: Failure = .none,
    motion: ?copy_mode.PointerMotion = null,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .leave = leave,
            .vertical = vertical,
            .pointer = pointer,
            .cancel_pointer = cancelPointer,
        };
    }

    fn cancelPointer(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .cancel_pointer;
        capture.event_count += 1;
    }

    fn pointer(raw_context: *anyopaque, motion: copy_mode.PointerMotion) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .pointer;
        capture.event_count += 1;
        capture.motion = motion;
    }

    fn leave(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .leave;
        capture.event_count += 1;

        if (capture.failure == .leave) {
            return error.CopyModeLeaveFailed;
        }
    }

    fn vertical(raw_context: *anyopaque, delta: i32) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .vertical;
        capture.event_count += 1;
        capture.delta = delta;

        if (capture.failure == .vertical) {
            return error.CopyModeMovementFailed;
        }
    }
};

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
