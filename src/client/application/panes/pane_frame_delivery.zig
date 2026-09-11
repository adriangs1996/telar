//! Application policy for delivering client resources after one committed
//! runtime pane frame.

const PaneFrameDeliveryTestingModel = @import("PaneFrameDeliveryTestingModel.zig");
const PaneFrameDeliveryEffectsCapture = @import("PaneFrameDeliveryEffectsCapture.zig");
const DeliverPaneFrameHandler = @import("DeliverPaneFrameHandler.zig");
const std = @import("std");

pub const Event = enum {
    read_graphics_visibility,
    set_graphics_visibility,
    synchronize_active_resources,
};

pub const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
};

test "DeliverPaneFrameHandler orders changed visibility before active resources" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = false,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .set_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expectEqual(testing.pane_id, capture.observed_pane.?);
    try std.testing.expectEqual(true, capture.delivered_visibility.?);
    try std.testing.expect(capture.current_visibility);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneFrameHandler preserves matching graphics visibility" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(?bool, null), capture.delivered_visibility);
}

test "DeliverPaneFrameHandler rejects stale topology and frame revisions" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.panes_revision -%= 1;

    testing.model.frame_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneFrameHandler rejects stale pane state" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };
    const pane = testing.model.workspace.findPane(testing.pane_id).?;

    pane.attached = false;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    pane.attached = true;

    pane.applied_frame_id += 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    pane.applied_frame_id -= 1;

    pane.scroll = .{ .total_rows = 3, .offset = 0 };
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneFrameHandler stops after graphics visibility failure" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = false,
        .failure = .graphics_visibility,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.GraphicsVisibilityFailed, handler.execute(commit));

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .set_graphics_visibility,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneFrameHandler propagates active resource failure after visibility" {
    var testing = try PaneFrameDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: PaneFrameDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
        .failure = .active_resources,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.ActiveResourceSyncFailed, handler.execute(commit));

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
