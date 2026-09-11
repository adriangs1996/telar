//! Application policy for delivering client resources after one committed pane
//! split confirmation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;

pub const Effects = @import("PaneSplitConfirmationDeliveryEffects.zig");

pub const DeliverPaneSplitConfirmationHandler = @import("DeliverPaneSplitConfirmationHandler.zig");

pub const Event = union(enum) {
    resize: schema.PaneId,
    synchronize_active_resources,
    detach: schema.PaneId,
    graphics_visibility: struct {
        pane_id: schema.PaneId,
        visible: bool,
    },
    workspace_snapshot_pending,
    request_workspace_snapshot: schema.WorkspaceLocation,
};

pub const Failure = enum {
    none,
    resize,
    active_resources,
    detach,
    graphics_visibility,
    workspace_snapshot,
};

const TestingModel = @import("PaneSplitConfirmationDeliveryTestingModel.zig");

const EffectsCapture = @import("PaneSplitConfirmationDeliveryEffectsCapture.zig");

fn deliveryHandler(capture: *EffectsCapture) DeliverPaneSplitConfirmationHandler {
    return .{
        .model = capture.model,
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverPaneSplitConfirmationHandler offers active geometry before resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: EffectsCapture = .{ .model = testing.model, .commit = commit };
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: EffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .detach = testing.created_pane },
        .{ .graphics_visibility = .{ .pane_id = testing.created_pane, .visible = false } },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneSplitConfirmationHandler detaches stale pane before canonical recovery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: EffectsCapture = .{ .model = testing.model, .commit = commit };
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: EffectsCapture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.foreignWorkspaceCommit();
    var capture: EffectsCapture = .{ .model = testing.model, .commit = commit };
    var handler = deliveryHandler(&capture);

    try handler.execute(commit);

    try std.testing.expectEqualDeep(&[_]Event{.{ .detach = testing.created_pane }}, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler rejects stale topology layout and attachment state" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: EffectsCapture = .{ .model = testing.model, .commit = commit };
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: EffectsCapture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.activeCommit();
    var capture: EffectsCapture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .failure = .detach,
    };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.PaneDetachFailed, handler.execute(commit));

    try std.testing.expectEqualDeep(&[_]Event{.{ .detach = testing.created_pane }}, capture.eventSlice());
}

test "DeliverPaneSplitConfirmationHandler preserves detach after graphics failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.inactiveCommit();
    var capture: EffectsCapture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.staleCommit();
    var capture: EffectsCapture = .{
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
