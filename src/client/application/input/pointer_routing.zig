//! Application policy for routing one normalized host pointer event.

const std = @import("std");
const pane_mouse = @import("pane_mouse.zig");

pub const PointerCommand = pane_mouse.PointerCommand;

pub const Authority = union(enum) {
    unavailable,
    available: PointerCommand,
};

pub const ViewOutcome = @import("ViewOutcome.zig");

pub const Outcome = enum {
    unavailable,
    copy_mode,
    view,
    link,
    pane,
};

pub const Effects = @import("PointerRoutingEffects.zig");

pub const PointerRoutingHandler = @import("PointerRoutingHandler.zig");

pub const Event = enum {
    copy_mode,
    view,
    link,
    pane,
};

pub const Failure = enum {
    none,
    copy_mode,
    view,
    link,
    pane,
};

const Capture = @import("PointerRoutingCapture.zig");

fn testingCommand() PointerCommand {
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
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view, .link, .pane }, capture.events[0..capture.event_count]);
}

test "pointer routing stops after a link claims the gesture" {
    var capture: Capture = .{ .link_consumed = true };
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Outcome.link, try handler.execute(.{ .available = testingCommand() }));
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view, .link }, capture.events[0..capture.event_count]);
}

test "pointer routing propagates a selected failure without later effects" {
    var capture: Capture = .{ .failure = .pane };
    var handler: PointerRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectError(
        error.PanePointerFailed,
        handler.execute(.{ .available = testingCommand() }),
    );
    try std.testing.expectEqualSlices(Event, &.{ .copy_mode, .view, .link, .pane }, capture.events[0..capture.event_count]);
}
