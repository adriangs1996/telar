//! Application policy for delivering one atomically committed workspace
//! creation replacement.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");
const workspace_transition_delivery = @import("workspace_transition_delivery.zig");

const schema = core.schema;

pub const DeliverWorkspaceCreationHandler = struct {
    model: *client_model.Model,
    release_effects: workspace_transition_delivery.ReleaseEffects,
    activation_effects: workspace_transition_delivery.ActivationEffects,

    /// Validates an exact replacement before releasing its departed resources
    /// and activating the runtime-created root.
    ///
    /// ```zig
    /// try handler.execute(&replacement);
    /// ```
    pub fn execute(handler: *DeliverWorkspaceCreationHandler, replacement: *const client_model.WorkspaceReplacement) !void {
        var activate: workspace_transition_delivery.ActivateWorkspaceHandler = .{
            .model = handler.model,
            .effects = handler.activation_effects,
        };
        try activate.validate(replacement.activation);
        try handler.validateDeparture(replacement);

        var release: workspace_transition_delivery.ReleaseWorkspaceResourcesHandler = .{
            .model = handler.model,
            .effects = handler.release_effects,
        };
        release.execute(&replacement.departure);

        try activate.execute(replacement.activation);
    }

    fn validateDeparture(handler: *const DeliverWorkspaceCreationHandler, replacement: *const client_model.WorkspaceReplacement) !void {
        const panes = replacement.departure.panes.slice();
        const source = replacement.departure.source orelse {
            if (replacement.departure.bookmark != null or panes.len != 0) {
                return error.StaleWorkspaceCreation;
            }
            return;
        };
        if (std.meta.eql(source, replacement.activation.location.workspace)) {
            return error.StaleWorkspaceCreation;
        }

        if (replacement.departure.bookmark) |bookmark| {
            if (!std.meta.eql(bookmark.location.workspace, source) or
                bookmark.tab_layout.focused() != bookmark.pane_id or
                !containsPane(panes, bookmark.pane_id))
            {
                return error.StaleWorkspaceCreation;
            }
        }

        for (panes, 0..) |pane_id, index| {
            if (pane_id == .invalid or
                pane_id == replacement.activation.pane_id or
                handler.model.workspace.findPane(pane_id) != null)
            {
                return error.StaleWorkspaceCreation;
            }

            for (panes[0..index]) |previous| {
                if (previous == pane_id) {
                    return error.StaleWorkspaceCreation;
                }
            }
        }
    }
};

fn containsPane(panes: []const schema.PaneId, wanted: schema.PaneId) bool {
    for (panes) |pane_id| {
        if (pane_id == wanted) {
            return true;
        }
    }

    return false;
}

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
    active_resources,
};

const TestingModel = struct {
    model: *client_model.Model,
    previous: schema.TabLocation,
    previous_root: schema.PaneId,
    previous_sibling: schema.PaneId,
    created: schema.TabLocation,
    created_root: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const previous: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const created: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        };
        const previous_root: schema.PaneId = @enumFromInt(1);
        const previous_sibling: schema.PaneId = @enumFromInt(2);
        const created_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(previous_root, previous, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(
            previous_root,
            previous_sibling,
            previous,
            .horizontal,
            .{ .w = 40, .h = 10 },
        );
        if (!model.workspace.active().?.model.focusPane(previous_root)) {
            return error.PreviousFocusNotRestored;
        }

        const pane = model.workspace.findPane(previous_root).?;
        pane.input_modes.bracketed_paste = true;
        pane.input_modes.focus_events = true;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        return .{
            .model = model,
            .previous = previous,
            .previous_root = previous_root,
            .previous_sibling = previous_sibling,
            .created = created,
            .created_root = created_root,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn replace(testing: *TestingModel) !client_model.WorkspaceReplacement {
        return testing.model.replaceWorkspace(.{
            .pane_id = testing.created_root,
            .location = testing.created,
            .size = .{ .cols = 50, .rows = 12 },
        });
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    replacement: *const client_model.WorkspaceReplacement,
    events: [12]Event = undefined,
    event_count: usize = 0,
    cleared_panes: [4]schema.PaneId = undefined,
    cleared_count: usize = 0,
    remembered: ?client_model.WorkspaceBookmark = null,
    workspace_request: ?schema.WorkspaceLocation = null,
    tab_request: ?schema.TabLocation = null,
    exact_commit_observed: bool = true,
    release_complete_before_activation: bool = false,
    failure: Failure = .none,

    fn releaseEffects(capture: *EffectsCapture) workspace_transition_delivery.ReleaseEffects {
        return .{
            .context = capture,
            .remember_bookmark = rememberBookmark,
            .clear_pane_graphics = clearPaneGraphics,
        };
    }

    fn activationEffects(capture: *EffectsCapture) workspace_transition_delivery.ActivationEffects {
        return .{
            .context = capture,
            .synchronize_active_resources = synchronizeActiveResources,
            .schedule_host_input = scheduleHostInput,
            .request_workspace_snapshot = requestWorkspaceSnapshot,
            .request_tab_snapshot = requestTabSnapshot,
        };
    }

    fn rememberBookmark(context: *anyopaque, bookmark: client_model.WorkspaceBookmark) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.remember_bookmark);
        capture.remembered = bookmark;
    }

    fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.clear_pane_graphics);
        capture.cleared_panes[capture.cleared_count] = pane_id;
        capture.cleared_count += 1;
    }

    fn synchronizeActiveResources(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.synchronize_active_resources);
        capture.release_complete_before_activation =
            capture.cleared_count == capture.replacement.departure.panes.slice().len and
            !capture.model.panePasteActive() and
            capture.model.reportedPaneFocus() == null;

        if (capture.failure == .active_resources) {
            return error.ActiveResourcesFailed;
        }
    }

    fn scheduleHostInput(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.schedule_host_input);
    }

    fn requestWorkspaceSnapshot(context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.request_workspace_snapshot);
        capture.workspace_request = workspace;
    }

    fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.request_tab_snapshot);
        capture.tab_request = location;
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.exact_commit_observed = capture.exact_commit_observed and capture.observesCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observesCommit(capture: *const EffectsCapture) bool {
        const activation = capture.replacement.activation;
        const version = capture.model.version();

        return std.meta.eql(capture.model.activeTabLocation(), activation.location) and
            version.workspace == activation.workspace_revision and
            version.tabs == activation.tabs_revision and
            version.active_tab == activation.active_tab_revision and
            version.panes == activation.panes_revision and
            version.copy == activation.copy_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn deliveryHandler(model: *client_model.Model, capture: *EffectsCapture) DeliverWorkspaceCreationHandler {
    return .{
        .model = model,
        .release_effects = capture.releaseEffects(),
        .activation_effects = capture.activationEffects(),
    };
}

test "DeliverWorkspaceCreationHandler releases before ordered activation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try handler.execute(&replacement);

    try std.testing.expectEqualSlices(Event, &.{
        .remember_bookmark,
        .clear_pane_graphics,
        .clear_pane_graphics,
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(replacement.departure.bookmark.?, capture.remembered.?);
    try std.testing.expectEqualSlices(schema.PaneId, replacement.departure.panes.slice(), capture.cleared_panes[0..capture.cleared_count]);
    try std.testing.expectEqualDeep(replacement.activation.location.workspace, capture.workspace_request.?);
    try std.testing.expectEqualDeep(replacement.activation.location, capture.tab_request.?);
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}

test "DeliverWorkspaceCreationHandler accepts an exact invalid-copy release" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const paste = testing.model.panePasteSession().?;
    try std.testing.expect(testing.model.finishPanePaste(paste));
    try std.testing.expect(testing.model.enterCopyMode());
    const replacement = try testing.replace();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try handler.execute(&replacement);

    try std.testing.expect(replacement.activation.copy_released);
    try std.testing.expectEqual(replacement.activation.copy_revision_before +% 1, replacement.activation.copy_revision);
    try std.testing.expect(!testing.model.copyModeActive());
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}

test "DeliverWorkspaceCreationHandler validates replacement before release" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(testing.model, &capture);

    var altered = replacement;
    altered.activation.workspace_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.workspace_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.tabs_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.active_tab_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.panes_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_revision_before -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_revision -%= 1;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.activation.copy_released = !altered.activation.copy_released;
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&altered));
    altered = replacement;
    altered.departure.source = replacement.activation.location.workspace;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.panes.items[1] = altered.departure.panes.items[0];
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.panes.items[0] = replacement.activation.pane_id;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    altered = replacement;
    altered.departure.bookmark.?.location.workspace = replacement.activation.location.workspace;
    try std.testing.expectError(error.StaleWorkspaceCreation, handler.execute(&altered));
    try testing.model.workspace.active().?.model.split(
        testing.created_root,
        @enumFromInt(4),
        testing.created,
        .vertical,
        .{ .w = 50, .h = 12 },
    );
    try std.testing.expectError(error.StaleWorkspaceActivation, handler.execute(&replacement));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverWorkspaceCreationHandler preserves release after activation failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const replacement = try testing.replace();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .replacement = &replacement,
        .failure = .active_resources,
    };
    var handler = deliveryHandler(testing.model, &capture);

    try std.testing.expectError(error.ActiveResourcesFailed, handler.execute(&replacement));

    try std.testing.expectEqual(
        Event.synchronize_active_resources,
        capture.eventSlice()[capture.event_count - 1],
    );
    try std.testing.expectEqual(replacement.departure.panes.slice().len, capture.cleared_count);
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
    try std.testing.expectEqualDeep(replacement.activation.location, testing.model.activeTabLocation().?);
}

test "DeliverWorkspaceCreationHandler activates an exact replacement from an empty source" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const replacement = try model.replaceWorkspace(.{
        .pane_id = @enumFromInt(3),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .size = .{ .cols = 50, .rows = 12 },
    });
    var capture: EffectsCapture = .{
        .model = &model,
        .replacement = &replacement,
    };
    var handler = deliveryHandler(&model, &capture);

    try handler.execute(&replacement);

    try std.testing.expectEqualSlices(Event, &.{
        .synchronize_active_resources,
        .schedule_host_input,
        .request_workspace_snapshot,
        .request_tab_snapshot,
    }, capture.eventSlice());
    try std.testing.expect(capture.release_complete_before_activation);
    try std.testing.expect(capture.exact_commit_observed);
}
