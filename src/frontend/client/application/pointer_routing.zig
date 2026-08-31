//! Application policy for routing one normalized host pointer event.

const std = @import("std");
const pane_mouse = @import("pane_mouse.zig");

pub const Command = pane_mouse.Command;

pub const Authority = union(enum) {
    unavailable,
    available: Command,
};

pub const ViewOutcome = struct {
    consume_pane_input: bool,
    pointer_inside: bool,
};

pub const Outcome = enum {
    unavailable,
    copy_mode,
    view,
    pane,
};

pub const Effects = struct {
    context: *anyopaque,
    copy_mode: *const fn (*anyopaque, Command) anyerror!bool,
    view: *const fn (*anyopaque, Command) anyerror!ViewOutcome,
    pane: *const fn (*anyopaque, Command) anyerror!void,
};

pub const PointerRoutingHandler = struct {
    effects: Effects,

    /// Gives each pointer event to the first owner that accepts it.
    ///
    /// ```zig
    /// const outcome = try handler.execute(authority);
    /// ```
    pub fn execute(handler: *PointerRoutingHandler, authority: Authority) !Outcome {
        const command = switch (authority) {
            .unavailable => return .unavailable,
            .available => |available| available,
        };

        if (try handler.effects.copy_mode(handler.effects.context, command)) {
            return .copy_mode;
        }

        const view = try handler.effects.view(handler.effects.context, command);
        if (view.consume_pane_input or !view.pointer_inside) {
            return .view;
        }

        try handler.effects.pane(handler.effects.context, command);
        return .pane;
    }
};

const Event = enum {
    copy_mode,
    view,
    pane,
};

const Failure = enum {
    none,
    copy_mode,
    view,
    pane,
};

const Capture = struct {
    events: [3]Event = undefined,
    event_count: usize = 0,
    copy_consumed: bool = false,
    view_outcome: ViewOutcome = .{
        .consume_pane_input = false,
        .pointer_inside = true,
    },
    failure: Failure = .none,

    fn port(capture: *Capture) Effects {
        return .{
            .context = capture,
            .copy_mode = copyMode,
            .view = view,
            .pane = pane,
        };
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn copyMode(raw_context: *anyopaque, command: Command) !bool {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = command;
        capture.record(.copy_mode);

        if (capture.failure == .copy_mode) {
            return error.CopyModePointerFailed;
        }

        return capture.copy_consumed;
    }

    fn view(raw_context: *anyopaque, command: Command) !ViewOutcome {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = command;
        capture.record(.view);

        if (capture.failure == .view) {
            return error.ViewPointerFailed;
        }

        return capture.view_outcome;
    }

    fn pane(raw_context: *anyopaque, command: Command) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = command;
        capture.record(.pane);

        if (capture.failure == .pane) {
            return error.PanePointerFailed;
        }
    }
};

fn testingCommand() Command {
    return .{
        .event = .{ .x = 4, .y = 7, .kind = .press },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}

test "pointer routing drops input without authority" {
    var capture: Capture = .{};
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Outcome.unavailable, try handler.execute(.unavailable));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "pointer routing stops after copy mode accepts the event" {
    var capture: Capture = .{ .copy_consumed = true };
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Outcome.copy_mode, try handler.execute(.{ .available = testingCommand() }));
    try std.testing.expectEqualSlices(Event, &.{.copy_mode}, capture.events[0..capture.event_count]);
}

test "pointer routing stops after consumed or outside view interaction" {
    var capture: Capture = .{ .view_outcome = .{
        .consume_pane_input = true,
        .pointer_inside = true,
    } };
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Outcome.view, try handler.execute(.{ .available = testingCommand() }));
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view }, capture.events[0..capture.event_count]);

    capture = .{ .view_outcome = .{
        .consume_pane_input = false,
        .pointer_inside = false,
    } };
    handler = .{ .effects = capture.port() };
    try std.testing.expectEqual(Outcome.view, try handler.execute(.{ .available = testingCommand() }));
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view }, capture.events[0..capture.event_count]);
}

test "pointer routing reaches pane input only after both earlier owners decline" {
    var capture: Capture = .{};
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Outcome.pane, try handler.execute(.{ .available = testingCommand() }));
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view, .pane }, capture.events[0..capture.event_count]);
}

test "pointer routing propagates a selected failure without later effects" {
    var capture: Capture = .{ .failure = .pane };
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectError(
        error.PanePointerFailed,
        handler.execute(.{ .available = testingCommand() }),
    );
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view, .pane }, capture.events[0..capture.event_count]);
}
