//! Application policy for releasing a departed workspace and activating its
//! committed replacement.

const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const ModelType = @import("../../model/Model.zig");
const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");
const std = @import("std");
const ReleaseCapture = @import("ReleaseCapture.zig");
const ReleaseWorkspaceResourcesHandler = @import("ReleaseWorkspaceResourcesHandler.zig");
const ActivationCapture = @import("ActivationCapture.zig");
const ActivateWorkspaceHandler = @import("ActivateWorkspaceHandler.zig");

pub const Event = enum {
    remember_bookmark,
    clear_pane_graphics,
    synchronize_active_resources,
    schedule_host_input,
    request_workspace_snapshot,
    request_tab_snapshot,
};

pub const Failure = enum {
    none,
    synchronize_active_resources,
    schedule_host_input,
    request_workspace_snapshot,
    request_tab_snapshot,
};

const testing_location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const testing_pane_id: PaneIdType = @enumFromInt(1);

fn prepareActivation(model: *ModelType) !WorkspaceActivationType {
    return model.arriveWorkspace(.{
        .pane_id = testing_pane_id,
        .location = testing_location,
        .size = .{ .cols = 20, .rows = 5 },
    });
}

test "ReleaseWorkspaceResourcesHandler remembers before releasing pane resources" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    try model.workspace.bootstrap(.{ .pane_id = testing_pane_id, .location = testing_location, .size = .{ .cols = 20, .rows = 5 } });
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;
    const departure = model.departWorkspace();
    var capture: ReleaseCapture = .{ .model = &model };
    var handler: ReleaseWorkspaceResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    handler.execute(&departure);

    try std.testing.expectEqualSlices(Event, &.{
        .remember_bookmark,
        .clear_pane_graphics,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(departure.bookmark.?, capture.bookmark.?);
    try std.testing.expectEqual(testing_pane_id, capture.cleared_panes[0]);
    try std.testing.expect(capture.released_state_observed);
    try std.testing.expect(!model.panePasteActive());
    try std.testing.expect(model.reportedPaneFocus() == null);
}

test "ActivateWorkspaceHandler orders resources and exact snapshot requests" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const activation = try prepareActivation(&model);
    var capture: ActivationCapture = .{
        .model = &model,
        .activation = activation,
    };
    var handler: ActivateWorkspaceHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(activation);

    try std.testing.expectEqualSlices(Event, &.{
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(testing_location.workspace, capture.workspace.?);
    try std.testing.expectEqualDeep(testing_location, capture.location.?);
    try std.testing.expect(capture.committed_activation_observed);
}

test "ActivateWorkspaceHandler rejects stale activation before effects" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const activation = try prepareActivation(&model);
    var capture: ActivationCapture = .{
        .model = &model,
        .activation = activation,
    };
    var handler: ActivateWorkspaceHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    var altered = activation;
    altered.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.tabs_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.active_tab_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.panes_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.copy_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.workspace_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.tabs_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.active_tab_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.panes_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.copy_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));
    altered = activation;
    altered.copy_released = !altered.copy_released;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(altered));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "ActivateWorkspaceHandler stops after each failed effect" {
    const failures = [_]Failure{
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    };
    const expected = [_][]const Event{
        &.{.synchronize_active_resources},
        &.{ .synchronize_active_resources, .schedule_host_input },
        &.{ .synchronize_active_resources, .schedule_host_input, .request_workspace_snapshot },
        &.{ .synchronize_active_resources, .schedule_host_input, .request_workspace_snapshot, .request_tab_snapshot },
    };
    const errors = [_]anyerror{
        error.ActiveResourceSyncFailed,
        error.HostInputScheduleFailed,
        error.WorkspaceSnapshotRequestFailed,
        error.TabSnapshotRequestFailed,
    };

    for (failures, expected, errors) |failure, events, expected_error| {
        var model = ModelType.init(std.testing.allocator, true);
        defer model.deinit();
        const activation = try prepareActivation(&model);
        var capture: ActivationCapture = .{
            .model = &model,
            .activation = activation,
            .failure = failure,
        };
        var handler: ActivateWorkspaceHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        try std.testing.expectError(expected_error, handler.execute(activation));
        try std.testing.expectEqualSlices(Event, events, capture.eventSlice());
        try std.testing.expect(capture.committed_activation_observed);
    }
}
