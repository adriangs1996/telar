//! Application policy for delivering client resources after one canonical
//! workspace snapshot commit.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const pane_geometry_delivery = @import("../panes/root.zig").pane_geometry_delivery;
const pane_resource_release = @import("../panes/root.zig").pane_resource_release;

pub const schema = core.schema;
pub const ui = core.ui;

pub const Effects = @import("WorkspaceSnapshotDeliveryEffects.zig");

pub const DeliverWorkspaceSnapshotHandler = @import("DeliverWorkspaceSnapshotHandler.zig");

pub const Event = union(enum) {
    ignore_tab: schema.TabId,
    clear_graphics: schema.PaneId,
    set_graphics_visible: struct {
        pane_id: schema.PaneId,
        visible: bool,
    },
    synchronize_active_resources,
    tab_snapshot_pending,
    request_tab_snapshot: schema.TabLocation,
    resize: schema.PaneId,
};

pub const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
    tab_snapshot,
    resize,
};

const TestingModel = @import("WorkspaceSnapshotDeliveryTestingModel.zig");

const EffectsCapture = @import("WorkspaceSnapshotDeliveryEffectsCapture.zig");

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverWorkspaceSnapshotHandler {
    return .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverWorkspaceSnapshotHandler releases retired resources before activating the canonical tab" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const old_pane = testing.model.workspace.findPane(testing.second_pane).?;
    old_pane.input_modes.bracketed_paste = true;
    old_pane.input_modes.focus_events = true;
    _ = testing.model.beginPanePaste().?;
    _ = testing.model.syncReportedPaneFocus().?;
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ignore_tab = testing.second.tab_id },
        .{ .clear_graphics = testing.second_pane },
        .{ .set_graphics_visible = .{ .pane_id = testing.first_pane, .visible = true } },
        .synchronize_active_resources,
        .tab_snapshot_pending,
        .{ .request_tab_snapshot = testing.first },
    }, capture.eventSlice());
    try std.testing.expect(capture.resources_released_before_graphics);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverWorkspaceSnapshotHandler offers geometry for a loaded canonical no-op" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    _ = try testing.reconcile();
    testing.model.workspace.active().?.snapshot_loaded = true;
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .tab_snapshot_pending,
        .{ .resize = testing.first_pane },
    }, capture.eventSlice());
    try std.testing.expectEqual(testing.first_pane, capture.delivered_resize.?.pane_id);
    try std.testing.expectEqual(@as(u16, 40), capture.delivered_resize.?.size.cols);
    try std.testing.expectEqual(@as(u16, 10), capture.delivered_resize.?.size.rows);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverWorkspaceSnapshotHandler preserves a pending tab snapshot" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    _ = try testing.reconcile();
    testing.model.workspace.active().?.snapshot_loaded = true;
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .pending_snapshot = true,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{.tab_snapshot_pending}, capture.eventSlice());
    try std.testing.expectEqual(@as(?schema.PaneResize, null), capture.delivered_resize);
}

test "DeliverWorkspaceSnapshotHandler requests an unloaded active tab snapshot" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .tab_snapshot_pending,
        .{ .request_tab_snapshot = testing.first },
    }, capture.eventSlice());
}

test "DeliverWorkspaceSnapshotHandler rejects stale revisions and snapshot state" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    var reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&testing, &capture);

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));
    testing.model.panes_revision -%= 1;

    reconciliation.active_tab_changed = !reconciliation.active_tab_changed;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));
    reconciliation.active_tab_changed = !reconciliation.active_tab_changed;

    testing.model.workspace.active().?.snapshot_loaded = !reconciliation.active_snapshot_loaded;
    try std.testing.expectError(error.StaleWorkspaceReconciliation, use_case.execute(&reconciliation));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverWorkspaceSnapshotHandler stops an active transition after graphics failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .graphics_visibility,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.GraphicsVisibilityFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ignore_tab = testing.second.tab_id },
        .{ .clear_graphics = testing.second_pane },
        .{ .set_graphics_visible = .{ .pane_id = testing.first_pane, .visible = true } },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverWorkspaceSnapshotHandler stops after active resource failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .active_resources,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.ActiveResourceSyncFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ignore_tab = testing.second.tab_id },
        .{ .clear_graphics = testing.second_pane },
        .{ .set_graphics_visible = .{ .pane_id = testing.first_pane, .visible = true } },
        .synchronize_active_resources,
    }, capture.eventSlice());
}

test "DeliverWorkspaceSnapshotHandler preserves the commit after tab snapshot failure" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .tab_snapshot,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.TabSnapshotRequestFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .tab_snapshot_pending,
        .{ .request_tab_snapshot = testing.first },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverWorkspaceSnapshotHandler preserves the commit after geometry failure" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    _ = try testing.reconcile();
    testing.model.workspace.active().?.snapshot_loaded = true;
    const reconciliation = try testing.reconcile();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .resize,
    };
    var use_case = deliveryHandler(&testing, &capture);

    try std.testing.expectError(error.PaneResizeFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .tab_snapshot_pending,
        .{ .resize = testing.first_pane },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
