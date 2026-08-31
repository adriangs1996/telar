//! Application policy for releasing a departed workspace and activating its
//! committed replacement.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");
const pane_resource_release = @import("pane_resource_release.zig");
const pane_focus_reporting = @import("pane_focus_reporting.zig");

const schema = core.schema;

pub const ReleaseEffects = struct {
    context: *anyopaque,
    remember_bookmark: *const fn (*anyopaque, client_model.WorkspaceBookmark) void,
    clear_pane_graphics: *const fn (*anyopaque, schema.PaneId) void,
};

pub const ActivationEffects = struct {
    context: *anyopaque,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    schedule_host_input: *const fn (*anyopaque) anyerror!void,
    request_workspace_snapshot: *const fn (*anyopaque, schema.WorkspaceLocation) anyerror!void,
    request_tab_snapshot: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const ReleaseWorkspaceResourcesHandler = struct {
    model: *client_model.Model,
    effects: ReleaseEffects,

    /// Remembers navigation before releasing each exact pane resource and
    /// silently retiring any remaining reported focus.
    ///
    /// ```zig
    /// handler.execute(&departure);
    /// ```
    pub fn execute(handler: *ReleaseWorkspaceResourcesHandler, departure: *const client_model.WorkspaceDeparture) void {
        if (departure.bookmark) |bookmark| {
            handler.effects.remember_bookmark(handler.effects.context, bookmark);
        }

        var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
            .model = handler.model,
            .effects = .{
                .context = handler.effects.context,
                .clear_graphics = handler.effects.clear_pane_graphics,
            },
        };
        for (departure.panes.slice()) |pane_id| {
            _ = release_pane.execute(pane_id);
        }

        var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
            .model = handler.model,
        };
        _ = retire_focus.execute();
    }
};

pub const ActivateWorkspaceHandler = struct {
    model: *client_model.Model,
    effects: ActivationEffects,

    /// Validates one exact activation before synchronizing active resources,
    /// host input and canonical snapshot requests in order.
    ///
    /// ```zig
    /// try handler.execute(activation);
    /// ```
    pub fn execute(handler: *ActivateWorkspaceHandler, activation: client_model.WorkspaceActivation) !void {
        try handler.validate(activation);
        try handler.effects.synchronize_active_resources(handler.effects.context);
        try handler.effects.schedule_host_input(handler.effects.context);
        try handler.effects.request_workspace_snapshot(
            handler.effects.context,
            activation.location.workspace,
        );
        try handler.effects.request_tab_snapshot(handler.effects.context, activation.location);
    }

    /// Rejects an activation that no longer proves the exact committed root,
    /// one-step semantic transition and copy release. Compound flows may
    /// validate before cleanup.
    ///
    /// ```zig
    /// try handler.validate(activation);
    /// ```
    pub fn validate(handler: *const ActivateWorkspaceHandler, activation: client_model.WorkspaceActivation) !void {
        const active = handler.model.workspace.activeConst() orelse return error.StaleWorkspaceActivation;
        const root = active.model.findConst(activation.pane_id) orelse return error.StaleWorkspaceActivation;
        const version = handler.model.version();
        if (!std.meta.eql(active.location, activation.location) or
            active.model.pane_count != 1 or
            active.model.layout.focused() != activation.pane_id or
            !std.meta.eql(root.location, activation.location) or
            !root.attached or
            version.workspace != activation.workspace_revision or
            version.tabs != activation.tabs_revision or
            version.active_tab != activation.active_tab_revision or
            version.panes != activation.panes_revision or
            version.copy != activation.copy_revision or
            activation.workspace_revision_before +% 1 != activation.workspace_revision or
            activation.tabs_revision_before +% 1 != activation.tabs_revision or
            activation.active_tab_revision_before +% 1 != activation.active_tab_revision or
            activation.panes_revision_before +% 1 != activation.panes_revision or
            activation.copy_revision_before +% @intFromBool(activation.copy_released) != activation.copy_revision)
        {
            return error.StaleWorkspaceActivation;
        }
    }
};

const Event = enum {
    remember_bookmark,
    clear_pane_graphics,
    synchronize_active_resources,
    schedule_host_input,
    request_workspace_snapshot,
    request_tab_snapshot,
};

const Failure = enum {
    none,
    synchronize_active_resources,
    schedule_host_input,
    request_workspace_snapshot,
    request_tab_snapshot,
};

const ReleaseCapture = struct {
    model: *const client_model.Model,
    events: [4]Event = undefined,
    event_count: usize = 0,
    bookmark: ?client_model.WorkspaceBookmark = null,
    cleared_panes: [4]schema.PaneId = undefined,
    cleared_count: usize = 0,
    released_state_observed: bool = true,

    fn effects(capture: *ReleaseCapture) ReleaseEffects {
        return .{
            .context = capture,
            .remember_bookmark = rememberBookmark,
            .clear_pane_graphics = clearPaneGraphics,
        };
    }

    fn rememberBookmark(raw_context: *anyopaque, bookmark: client_model.WorkspaceBookmark) void {
        const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .remember_bookmark;
        capture.event_count += 1;
        capture.bookmark = bookmark;
    }

    fn clearPaneGraphics(raw_context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
        capture.events[capture.event_count] = .clear_pane_graphics;
        capture.event_count += 1;
        capture.cleared_panes[capture.cleared_count] = pane_id;
        capture.cleared_count += 1;
        capture.released_state_observed = capture.released_state_observed and
            !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
    }

    fn eventSlice(capture: *const ReleaseCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

const ActivationCapture = struct {
    model: *const client_model.Model,
    activation: client_model.WorkspaceActivation,
    events: [4]Event = undefined,
    event_count: usize = 0,
    committed_activation_observed: bool = true,
    workspace: ?schema.WorkspaceLocation = null,
    location: ?schema.TabLocation = null,
    failure: Failure = .none,

    fn effects(capture: *ActivationCapture) ActivationEffects {
        return .{
            .context = capture,
            .synchronize_active_resources = synchronizeActiveResources,
            .schedule_host_input = scheduleHostInput,
            .request_workspace_snapshot = requestWorkspaceSnapshot,
            .request_tab_snapshot = requestTabSnapshot,
        };
    }

    fn synchronizeActiveResources(raw_context: *anyopaque) !void {
        const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.synchronize_active_resources);

        if (capture.failure == .synchronize_active_resources) {
            return error.ActiveResourceSyncFailed;
        }
    }

    fn scheduleHostInput(raw_context: *anyopaque) !void {
        const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.schedule_host_input);

        if (capture.failure == .schedule_host_input) {
            return error.HostInputScheduleFailed;
        }
    }

    fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
        const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.request_workspace_snapshot);
        capture.workspace = workspace;

        if (capture.failure == .request_workspace_snapshot) {
            return error.WorkspaceSnapshotRequestFailed;
        }
    }

    fn requestTabSnapshot(raw_context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.request_tab_snapshot);
        capture.location = location;

        if (capture.failure == .request_tab_snapshot) {
            return error.TabSnapshotRequestFailed;
        }
    }

    fn append(capture: *ActivationCapture, event: Event) void {
        const version = capture.model.version();
        capture.committed_activation_observed = capture.committed_activation_observed and
            std.meta.eql(capture.model.activeTabLocation(), capture.activation.location) and
            version.workspace == capture.activation.workspace_revision and
            version.tabs == capture.activation.tabs_revision and
            version.active_tab == capture.activation.active_tab_revision and
            version.panes == capture.activation.panes_revision and
            version.copy == capture.activation.copy_revision;
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const ActivationCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const testing_pane_id: schema.PaneId = @enumFromInt(1);

fn prepareActivation(model: *client_model.Model) !client_model.WorkspaceActivation {
    return model.arriveWorkspace(.{
        .pane_id = testing_pane_id,
        .location = testing_location,
        .size = .{ .cols = 20, .rows = 5 },
    });
}

test "ReleaseWorkspaceResourcesHandler remembers before releasing pane resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try model.workspace.bootstrap(testing_pane_id, testing_location, .{ .cols = 20, .rows = 5 });
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
    var model = client_model.Model.init(std.testing.allocator, true);
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
    var model = client_model.Model.init(std.testing.allocator, true);
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
        var model = client_model.Model.init(std.testing.allocator, true);
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
