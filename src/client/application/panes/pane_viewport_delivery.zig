//! Application policy for delivering one committed pane viewport.

const DeliverPaneViewportHandler = @import("DeliverPaneViewportHandler.zig");
const PaneViewportDeliveryEffectsCapture = @import("PaneViewportDeliveryEffectsCapture.zig");
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const std = @import("std");
const PaneViewportDeliveryTestingModel = @import("PaneViewportDeliveryTestingModel.zig");
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const ModelType = @import("../../model/Model.zig");

pub const Event = enum {
    graphics,
    runtime,
};

pub const Failure = enum {
    none,
    graphics,
    runtime,
};

fn expectStale(handler: *const DeliverPaneViewportHandler, capture: *PaneViewportDeliveryEffectsCapture, change: PaneViewportChangeType) !void {
    try std.testing.expectError(error.StalePaneViewport, handler.execute(change));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneViewportHandler orders graphics before runtime delivery" {
    var testing = try PaneViewportDeliveryTestingModel.init();
    defer testing.deinit();
    const change = testing.commitBottom();
    var capture: PaneViewportDeliveryEffectsCapture = .{};
    const handler: DeliverPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(change);

    try std.testing.expectEqualSlices(Event, &.{ .graphics, .runtime }, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(change.pane_id, capture.graphics_pane.?);
    try std.testing.expect(capture.visible.?);
    try std.testing.expectEqualDeep(SetPaneViewportType{
        .pane_id = change.pane_id,
        .offset = change.offset,
    }, capture.viewport.?);
}

test "DeliverPaneViewportHandler rejects every stale commit before effects" {
    var testing = try PaneViewportDeliveryTestingModel.init();
    defer testing.deinit();
    const change = testing.commitBottom();
    var capture: PaneViewportDeliveryEffectsCapture = .{};
    const handler: DeliverPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    var stale = change;
    stale.pane_id = @enumFromInt(9);
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.offset -= 1;
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.at_bottom = false;
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.viewport_revision +%= 1;
    try expectStale(&handler, &capture, stale);

    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    try expectStale(&handler, &capture, change);
    testing.model.workspace.findPane(testing.pane_id).?.attached = true;

    var empty = ModelType.init(std.testing.allocator, true);
    defer empty.deinit();
    const empty_handler: DeliverPaneViewportHandler = .{
        .model = &empty,
        .effects = capture.effects(),
    };
    try expectStale(&empty_handler, &capture, change);
}

test "DeliverPaneViewportHandler preserves completed effects after delivery failure" {
    inline for (.{ Failure.graphics, Failure.runtime }) |failure| {
        var testing = try PaneViewportDeliveryTestingModel.init();
        defer testing.deinit();
        const change = testing.commitBottom();
        var capture: PaneViewportDeliveryEffectsCapture = .{ .failure = failure };
        const handler: DeliverPaneViewportHandler = .{
            .model = testing.model,
            .effects = capture.effects(),
        };

        const expected_error = switch (failure) {
            .graphics => error.GraphicsDeliveryFailed,
            .runtime => error.RuntimeDeliveryFailed,
            .none => unreachable,
        };
        try std.testing.expectError(expected_error, handler.execute(change));

        const expected_events: []const Event = switch (failure) {
            .graphics => &.{.graphics},
            .runtime => &.{ .graphics, .runtime },
            .none => unreachable,
        };
        try std.testing.expectEqualSlices(Event, expected_events, capture.events[0..capture.event_count]);
        try std.testing.expectEqual(change.offset, testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
        try std.testing.expectEqual(change.viewport_revision, testing.model.version().viewport);
    }
}
