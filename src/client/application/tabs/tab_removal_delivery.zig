//! Application policy for delivering disposable client resources after one
//! canonical tab-removal commit.

const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TabRemovalDeliveryTestingModel = @import("TabRemovalDeliveryTestingModel.zig");
const TabRemovalDeliveryEffectsCapture = @import("TabRemovalDeliveryEffectsCapture.zig");
const DeliverTabRemovalHandler = @import("DeliverTabRemovalHandler.zig");
const types = @import("../../model/types.zig");
const std = @import("std");
const close_tab = @import("close_tab.zig");

pub const Event = union(enum) {
    retire_tab_requests: TabLocationType,
    clear_graphics: PaneIdType,
    graphics_visibility: struct {
        pane_id: PaneIdType,
        visible: bool,
    },
    synchronize_active_resources,
    tab_snapshot_pending,
    request_tab_snapshot: TabLocationType,
    forget_workspace: WorkspaceLocationType,
    request_workspace: WorkspaceIdType,
};

pub const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
    tab_snapshot,
    workspace_handoff,
};

fn deliveryHandler(testing: *TabRemovalDeliveryTestingModel, capture: *TabRemovalDeliveryEffectsCapture) DeliverTabRemovalHandler {
    return .{
        .model = testing.model,
        .effects = capture.effects(),
    };
}

fn captureFor(testing: *TabRemovalDeliveryTestingModel, commit: types.TabRemovalCommit) TabRemovalDeliveryEffectsCapture {
    return .{
        .model = testing.model,
        .commit = commit,
    };
}

test "DeliverTabRemovalHandler releases an active tab before activating its successor" {
    var testing = try TabRemovalDeliveryTestingModel.init(true);
    defer testing.deinit();
    const commit = try testing.removeActive();
    var capture = captureFor(&testing, commit);
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectEqual(
        close_tab.TabRemovalDirective.continue_running,
        try handler.execute(commit, null),
    );

    try std.testing.expectEqualSlices(Event, &.{
        .{ .retire_tab_requests = testing.removed },
        .{ .clear_graphics = testing.removed_root },
        .{ .clear_graphics = testing.removed_sibling },
        .{ .graphics_visibility = .{ .pane_id = testing.successor_root, .visible = true } },
        .synchronize_active_resources,
        .tab_snapshot_pending,
        .{ .request_tab_snapshot = testing.successor },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expect(capture.pane_authorities_released);
    try std.testing.expect(capture.focus_retired_before_activation);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
}

test "DeliverTabRemovalHandler limits inactive removal to exact tab resources" {
    var testing = try TabRemovalDeliveryTestingModel.init(true);
    defer testing.deinit();
    const commit = try testing.removeInactive();
    var capture = captureFor(&testing, commit);
    var handler = deliveryHandler(&testing, &capture);

    try std.testing.expectEqual(
        close_tab.TabRemovalDirective.continue_running,
        try handler.execute(commit, null),
    );

    try std.testing.expectEqualSlices(Event, &.{
        .{ .retire_tab_requests = testing.successor },
        .{ .clear_graphics = testing.successor_root },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expect(capture.pane_authorities_released);
    try std.testing.expectEqual(testing.removed_root, testing.model.reportedPaneFocus().?.pane_id);
    try std.testing.expect(testing.model.panePasteActive());
}

test "DeliverTabRemovalHandler coalesces a successor snapshot already in flight" {
    var testing = try TabRemovalDeliveryTestingModel.init(true);
    defer testing.deinit();
    const commit = try testing.removeActive();
    var capture = captureFor(&testing, commit);
    capture.snapshot_pending = true;
    var handler = deliveryHandler(&testing, &capture);

    _ = try handler.execute(commit, null);

    try std.testing.expectEqual(Event.tab_snapshot_pending, capture.eventSlice()[capture.event_count - 1]);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabRemovalHandler chooses final workspace exit or handoff after cleanup" {
    var exit_testing = try TabRemovalDeliveryTestingModel.init(false);
    defer exit_testing.deinit();
    const exit_commit = try exit_testing.removeWorkspace();
    var exit_capture = captureFor(&exit_testing, exit_commit);
    var exit_handler = deliveryHandler(&exit_testing, &exit_capture);

    try std.testing.expectEqual(
        close_tab.TabRemovalDirective.exit,
        try exit_handler.execute(exit_commit, null),
    );
    try std.testing.expectEqualSlices(Event, &.{
        .{ .retire_tab_requests = exit_testing.removed },
        .{ .clear_graphics = exit_testing.removed_root },
        .{ .clear_graphics = exit_testing.removed_sibling },
        .{ .forget_workspace = exit_testing.removed.workspace },
    }, exit_capture.eventSlice());
    try std.testing.expect(exit_capture.committed_state_observed);

    var handoff_testing = try TabRemovalDeliveryTestingModel.init(false);
    defer handoff_testing.deinit();
    const handoff_commit = try handoff_testing.removeWorkspace();
    var handoff_capture = captureFor(&handoff_testing, handoff_commit);
    var handoff_handler = deliveryHandler(&handoff_testing, &handoff_capture);
    const previous: WorkspaceIdType = @enumFromInt(9);

    try std.testing.expectEqual(
        close_tab.TabRemovalDirective.continue_running,
        try handoff_handler.execute(handoff_commit, previous),
    );
    try std.testing.expectEqualDeep(
        Event{ .request_workspace = previous },
        handoff_capture.eventSlice()[handoff_capture.event_count - 1],
    );
    try std.testing.expect(handoff_capture.committed_state_observed);
}

test "DeliverTabRemovalHandler applies exact stale cleanup without resource effects" {
    var tab_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer tab_testing.deinit();
    const missing: TabLocationType = .{
        .workspace = tab_testing.removed.workspace,
        .tab_id = @enumFromInt(9),
    };
    const tab_commit = try tab_testing.model.removeTab(.{
        .location = missing,
        .workspace_removed = false,
    });
    var tab_capture = captureFor(&tab_testing, tab_commit);
    var tab_handler = deliveryHandler(&tab_testing, &tab_capture);

    _ = try tab_handler.execute(tab_commit, null);

    try std.testing.expectEqualSlices(Event, &.{.{ .retire_tab_requests = missing }}, tab_capture.eventSlice());
    try std.testing.expect(tab_capture.committed_state_observed);

    var workspace_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer workspace_testing.deinit();
    const foreign: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(7),
    };
    const workspace_commit = try workspace_testing.model.removeTab(.{
        .location = foreign,
        .workspace_removed = true,
    });
    var workspace_capture = captureFor(&workspace_testing, workspace_commit);
    var workspace_handler = deliveryHandler(&workspace_testing, &workspace_capture);

    _ = try workspace_handler.execute(workspace_commit, @enumFromInt(8));

    try std.testing.expectEqualSlices(Event, &.{.{ .retire_tab_requests = foreign }}, workspace_capture.eventSlice());
    try std.testing.expect(workspace_capture.committed_state_observed);
}

test "DeliverTabRemovalHandler rejects altered removal commits before cleanup" {
    var testing = try TabRemovalDeliveryTestingModel.init(true);
    defer testing.deinit();
    const commit = try testing.removeActive();
    var capture = captureFor(&testing, commit);
    var handler = deliveryHandler(&testing, &capture);

    var wrong_revision = commit;
    wrong_revision.removed.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_revision, null));
    wrong_revision = commit;
    wrong_revision.removed.tabs_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_revision, null));
    wrong_revision = commit;
    wrong_revision.removed.active_tab_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_revision, null));
    wrong_revision = commit;
    wrong_revision.removed.panes_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_revision, null));
    wrong_revision = commit;
    wrong_revision.removed.copy_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_revision, null));

    var wrong_layout = commit;
    wrong_layout.removed.active_layout_revision -%= 1;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_layout, null));

    var wrong_activity = commit;
    wrong_activity.removed.was_active = false;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_activity, null));

    var wrong_workspace = commit;
    wrong_workspace.removed.workspace_removed = true;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_workspace, null));

    var wrong_active = commit;
    wrong_active.removed.active = testing.removed;
    try std.testing.expectError(error.StaleTabRemoval, handler.execute(wrong_active, null));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverTabRemovalHandler catches active identity and layout ABA plus represented retired panes" {
    var identity_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer identity_testing.deinit();
    const identity_commit = try identity_testing.removeActive();
    var identity_capture = captureFor(&identity_testing, identity_commit);
    var identity_handler = deliveryHandler(&identity_testing, &identity_capture);
    _ = try identity_testing.model.workspace.addCreated(.{
        .location = .{
            .workspace = identity_testing.successor.workspace,
            .tab_id = @enumFromInt(3),
        },
        .position = 1,
        .label = "late",
        .root_pane_id = @enumFromInt(4),
    }, .{ .cols = 40, .rows = 10 });

    try std.testing.expectError(error.StaleTabRemoval, identity_handler.execute(identity_commit, null));
    try std.testing.expectEqual(@as(usize, 0), identity_capture.event_count);

    var layout_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer layout_testing.deinit();
    const layout_commit = try layout_testing.removeActive();
    var layout_capture = captureFor(&layout_testing, layout_commit);
    var layout_handler = deliveryHandler(&layout_testing, &layout_capture);
    layout_testing.model.workspace.active().?.model.setPaneGaps(false);

    try std.testing.expectError(error.StaleTabRemoval, layout_handler.execute(layout_commit, null));
    try std.testing.expectEqual(@as(usize, 0), layout_capture.event_count);

    var pane_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer pane_testing.deinit();
    const pane_commit = try pane_testing.removeActive();
    var pane_capture = captureFor(&pane_testing, pane_commit);
    var pane_handler = deliveryHandler(&pane_testing, &pane_capture);
    try pane_testing.model.workspace.active().?.model.split(.{ .existing_pane = pane_testing.successor_root, .new_pane = pane_testing.removed_root, .location = pane_testing.successor, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    pane_capture.commit.removed.active_layout_revision =
        pane_testing.model.workspace.activeConst().?.model.layout.currentRevision();

    try std.testing.expectError(error.StaleTabRemoval, pane_handler.execute(pane_capture.commit, null));
    try std.testing.expectEqual(@as(usize, 0), pane_capture.event_count);
}

test "DeliverTabRemovalHandler rejects stale absence contradicted by current state" {
    var tab_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer tab_testing.deinit();
    const missing: TabLocationType = .{
        .workspace = tab_testing.removed.workspace,
        .tab_id = @enumFromInt(9),
    };
    const tab_commit = try tab_testing.model.removeTab(.{
        .location = missing,
        .workspace_removed = false,
    });
    var tab_capture = captureFor(&tab_testing, tab_commit);
    var tab_handler = deliveryHandler(&tab_testing, &tab_capture);
    _ = try tab_testing.model.workspace.addCreated(.{
        .location = missing,
        .position = 2,
        .label = "late",
        .root_pane_id = @enumFromInt(9),
    }, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.StaleTabRemoval, tab_handler.execute(tab_commit, null));
    try std.testing.expectEqual(@as(usize, 0), tab_capture.event_count);

    var workspace_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer workspace_testing.deinit();
    const foreign: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(7),
    };
    const workspace_commit = try workspace_testing.model.removeTab(.{
        .location = foreign,
        .workspace_removed = true,
    });
    _ = workspace_testing.model.departWorkspace();
    try workspace_testing.model.workspace.bootstrap(.{ .pane_id = @enumFromInt(7), .location = foreign, .size = .{ .cols = 20, .rows = 5 } });
    var workspace_capture = captureFor(&workspace_testing, workspace_commit);
    const version = workspace_testing.model.version();
    workspace_capture.commit.stale.workspace_revision = version.workspace;
    workspace_capture.commit.stale.tabs_revision = version.tabs;
    workspace_capture.commit.stale.active_tab_revision = version.active_tab;
    workspace_capture.commit.stale.panes_revision = version.panes;
    workspace_capture.commit.stale.copy_revision = version.copy;
    var workspace_handler = deliveryHandler(&workspace_testing, &workspace_capture);

    try std.testing.expectError(
        error.StaleTabRemoval,
        workspace_handler.execute(workspace_capture.commit, null),
    );
    try std.testing.expectEqual(@as(usize, 0), workspace_capture.event_count);
}

test "DeliverTabRemovalHandler preserves completed cleanup across delivery failures" {
    var visibility_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer visibility_testing.deinit();
    const visibility_commit = try visibility_testing.removeActive();
    var visibility_capture = captureFor(&visibility_testing, visibility_commit);
    visibility_capture.failure = .graphics_visibility;
    var visibility_handler = deliveryHandler(&visibility_testing, &visibility_capture);

    try std.testing.expectError(
        error.GraphicsVisibilityFailed,
        visibility_handler.execute(visibility_commit, null),
    );
    try std.testing.expect(!visibility_testing.model.panePasteActive());
    try std.testing.expect(visibility_testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(
        Event{ .graphics_visibility = .{
            .pane_id = visibility_testing.successor_root,
            .visible = true,
        } },
        visibility_capture.eventSlice()[visibility_capture.event_count - 1],
    );

    var resources_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer resources_testing.deinit();
    const resources_commit = try resources_testing.removeActive();
    var resources_capture = captureFor(&resources_testing, resources_commit);
    resources_capture.failure = .active_resources;
    var resources_handler = deliveryHandler(&resources_testing, &resources_capture);

    try std.testing.expectError(
        error.ActiveResourceSynchronizationFailed,
        resources_handler.execute(resources_commit, null),
    );
    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        resources_capture.eventSlice()[resources_capture.event_count - 1],
    );

    var snapshot_testing = try TabRemovalDeliveryTestingModel.init(true);
    defer snapshot_testing.deinit();
    const snapshot_commit = try snapshot_testing.removeActive();
    var snapshot_capture = captureFor(&snapshot_testing, snapshot_commit);
    snapshot_capture.failure = .tab_snapshot;
    var snapshot_handler = deliveryHandler(&snapshot_testing, &snapshot_capture);

    try std.testing.expectError(
        error.TabSnapshotRequestFailed,
        snapshot_handler.execute(snapshot_commit, null),
    );
    try std.testing.expectEqualDeep(
        Event{ .request_tab_snapshot = snapshot_testing.successor },
        snapshot_capture.eventSlice()[snapshot_capture.event_count - 1],
    );

    try std.testing.expect(visibility_capture.committed_state_observed);
    try std.testing.expect(resources_capture.committed_state_observed);
    try std.testing.expect(snapshot_capture.committed_state_observed);
}

test "DeliverTabRemovalHandler retains forgotten navigation after handoff failure" {
    var testing = try TabRemovalDeliveryTestingModel.init(false);
    defer testing.deinit();
    const commit = try testing.removeWorkspace();
    var capture = captureFor(&testing, commit);
    capture.failure = .workspace_handoff;
    var handler = deliveryHandler(&testing, &capture);
    const previous: WorkspaceIdType = @enumFromInt(9);

    try std.testing.expectError(
        error.WorkspaceHandoffFailed,
        handler.execute(commit, previous),
    );
    try std.testing.expectEqualSlices(Event, &.{
        .{ .retire_tab_requests = testing.removed },
        .{ .clear_graphics = testing.removed_root },
        .{ .clear_graphics = testing.removed_sibling },
        .{ .forget_workspace = testing.removed.workspace },
        .{ .request_workspace = previous },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
