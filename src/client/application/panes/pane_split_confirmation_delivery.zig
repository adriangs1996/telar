//! Application policy for delivering client resources after one committed pane
//! split confirmation.

const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneSplitConfirmationDeliveryEffectsCapture = @import("PaneSplitConfirmationDeliveryEffectsCapture.zig");
const DeliverPaneSplitConfirmationHandler = @import("DeliverPaneSplitConfirmationHandler.zig");
const PaneSplitConfirmationDeliveryTestingModel = @import("PaneSplitConfirmationDeliveryTestingModel.zig");
const std = @import("std");

pub const Event = union(enum) {
    resize: PaneIdType,
    synchronize_active_resources,
    detach: PaneIdType,
    graphics_visibility: struct {
        pane_id: PaneIdType,
        visible: bool,
    },
    workspace_snapshot_pending,
    request_workspace_snapshot: WorkspaceLocationType,
};

pub const Failure = enum {
    none,
    resize,
    active_resources,
    detach,
    graphics_visibility,
    workspace_snapshot,
};

fn deliveryHandler(capture: *PaneSplitConfirmationDeliveryEffectsCapture) DeliverPaneSplitConfirmationHandler {
    return .{
        .model = capture.model,
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverPaneSplitConfirmationHandler offers active geometry before resources" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .resize = testing.first_pane },
        .{ .resize = testing.created_pane },
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneSplitConfirmationHandler detaches and hides an inactive pane" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .{ .graphics_visibility = .{ .pane_id = testing.created_pane, .visible = false } },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneSplitConfirmationHandler detaches stale pane before canonical recovery" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .workspace_snapshot_pending,
        .{ .request_workspace_snapshot = testing.first.workspace },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneSplitConfirmationHandler coalesces stale workspace recovery" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .snapshot_pending = true,
    };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .workspace_snapshot_pending,
    }, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler skips recovery for another workspace" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.foreignWorkspaceCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{.{ .detach = testing.created_pane }}, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler rejects stale topology layout and attachment state" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));
    testing.model.panes_revision -%= 1;

    const tab = testing.model.workspace.find(testing.first.tab_id).?;
    const pane = tab.model.find(testing.created_pane).?;
    pane.attached = false;
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));
    pane.attached = true;

    try std.testing.expect(tab.model.focusPane(testing.first_pane));
    try std.testing.expectError(error.StalePaneSplitConfirmation, handler.execute(commit));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneSplitConfirmationHandler stops active delivery after geometry failure" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .resize,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.PaneResizeFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{.{ .resize = testing.first_pane }}, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneSplitConfirmationHandler propagates active resource failure after geometry" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .active_resources,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.ActiveResourceSyncFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .resize = testing.first_pane },
        .{ .resize = testing.created_pane },
        .synchronize_active_resources,
    }, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler stops inactive delivery after detach failure" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .detach,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.PaneDetachFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{.{ .detach = testing.created_pane }}, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler preserves detach after graphics failure" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .graphics_visibility,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.GraphicsVisibilityFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .{ .graphics_visibility = .{ .pane_id = testing.created_pane, .visible = false } },
    }, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler preserves detach after recovery failure" {
    var testing = try PaneSplitConfirmationDeliveryTestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: PaneSplitConfirmationDeliveryEffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .workspace_snapshot,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.WorkspaceSnapshotRequestFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .workspace_snapshot_pending,
        .{ .request_workspace_snapshot = testing.first.workspace },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
