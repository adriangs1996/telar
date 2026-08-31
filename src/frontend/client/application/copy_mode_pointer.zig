//! Application policy for pointer events while copy mode owns input.

const std = @import("std");
const presentation = @import("../../presentation/root.zig");

const term = presentation.screen;

pub const Command = struct {
    kind: term.Event.Mouse.Kind,
};

pub const Authority = union(enum) {
    unowned,
    target_missing,
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
};

pub const CopyModePointerHandler = struct {
    effects: Effects,

    /// Consumes every pointer event owned by copy mode. Only a wheel inside
    /// the captured pane moves, while a missing target exits local copy state.
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
};

const Failure = enum {
    none,
    leave,
    vertical,
};

const EffectsCapture = struct {
    events: [1]Event = undefined,
    event_count: usize = 0,
    delta: i32 = 0,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .leave = leave,
            .vertical = vertical,
        };
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
