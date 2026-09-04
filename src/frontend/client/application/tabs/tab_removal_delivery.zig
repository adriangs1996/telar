//! Application policy for delivering disposable client resources after one
//! canonical tab-removal commit.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");
const close_tab = @import("close_tab.zig");
const pane_focus_reporting = @import("../panes/pane_focus_reporting.zig");
const pane_resource_release = @import("../panes/pane_resource_release.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Effects = struct {
    context: *anyopaque,
    retire_tab_requests: *const fn (*anyopaque, schema.TabLocation) void,
    clear_pane_graphics: *const fn (*anyopaque, schema.PaneId) void,
    set_pane_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    tab_snapshot_pending: *const fn (*anyopaque) bool,
    request_tab_snapshot: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    forget_workspace: *const fn (*anyopaque, schema.WorkspaceLocation) void,
    request_workspace: *const fn (*anyopaque, schema.WorkspaceId) anyerror!void,
};

pub const DeliverTabRemovalHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Validates one exact removed or stale commit before retiring resources,
    /// activating a successor tab and choosing workspace handoff or exit.
    ///
    /// ```zig
    /// const directive = try handler.execute(commit, previous_workspace);
    /// ```
    pub fn execute(handler: *DeliverTabRemovalHandler, commit: client_model.TabRemovalCommit, previous_workspace: ?schema.WorkspaceId) !close_tab.TabRemovalDirective {
        try handler.validate(commit);

        const removal = switch (commit) {
            .stale => |stale| {
                handler.effects.retire_tab_requests(handler.effects.context, stale.location);
                return .continue_running;
            },
            .removed => |removed| removed,
        };
        handler.effects.retire_tab_requests(handler.effects.context, removal.removed);

        var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
            .model = handler.model,
            .effects = .{
                .context = handler.effects.context,
                .clear_graphics = handler.effects.clear_pane_graphics,
            },
        };
        for (removal.panes.slice()) |pane_id| {
            _ = release_pane.execute(pane_id);
        }

        if (removal.was_active) {
            var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
                .model = handler.model,
            };
            _ = retire_focus.execute();

            if (removal.active) |active_location| {
                const active = try handler.exactTab(active_location);
                var panes = active.model.paneIterator();
                while (panes.next()) |pane| {
                    try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
                }

                try handler.effects.synchronize_active_resources(handler.effects.context);
                if (!handler.effects.tab_snapshot_pending(handler.effects.context)) {
                    try handler.effects.request_tab_snapshot(handler.effects.context, active_location);
                }
            }
        }

        if (!removal.workspace_removed) {
            return .continue_running;
        }

        handler.effects.forget_workspace(handler.effects.context, removal.removed.workspace);
        const previous = previous_workspace orelse return .exit;
        try handler.effects.request_workspace(handler.effects.context, previous);

        return .continue_running;
    }

    fn validate(handler: *const DeliverTabRemovalHandler, commit: client_model.TabRemovalCommit) !void {
        const version = handler.model.version();
        switch (commit) {
            .stale => |stale| {
                if (version.workspace != stale.workspace_revision or
                    version.tabs != stale.tabs_revision or
                    version.active_tab != stale.active_tab_revision or
                    version.panes != stale.panes_revision or
                    version.copy != stale.copy_revision)
                {
                    return error.StaleTabRemoval;
                }

                const workspace = handler.model.workspace.workspace;
                switch (stale.absence) {
                    .workspace => if (workspace != null and std.meta.eql(workspace.?, stale.location.workspace)) {
                        return error.StaleTabRemoval;
                    },
                    .tab => {
                        if (workspace == null or !std.meta.eql(workspace.?, stale.location.workspace)) {
                            return error.StaleTabRemoval;
                        }
                        if (handler.model.workspace.find(stale.location.tab_id) != null) {
                            return error.StaleTabRemoval;
                        }
                    },
                }
            },
            .removed => |removal| {
                if (version.workspace != removal.workspace_revision or
                    version.tabs != removal.tabs_revision or
                    version.active_tab != removal.active_tab_revision or
                    version.panes != removal.panes_revision or
                    version.copy != removal.copy_revision or
                    removal.active_tab_revision_before +% @intFromBool(removal.was_active) != removal.active_tab_revision or
                    handler.model.workspace.find(removal.removed.tab_id) != null)
                {
                    return error.StaleTabRemoval;
                }

                for (removal.panes.slice()) |pane_id| {
                    if (handler.model.workspace.tabForPaneConst(pane_id) != null) {
                        return error.StaleTabRemoval;
                    }
                }

                if (removal.workspace_removed) {
                    if (!removal.was_active or removal.active != null or
                        removal.active_layout_revision != 0 or
                        handler.model.workspace.workspace != null)
                    {
                        return error.StaleTabRemoval;
                    }
                    return;
                }

                const workspace = handler.model.workspace.workspace orelse return error.StaleTabRemoval;
                const active_location = removal.active orelse return error.StaleTabRemoval;
                const current_active = handler.model.activeTabLocation() orelse return error.StaleTabRemoval;
                if (!std.meta.eql(workspace, removal.removed.workspace) or
                    std.meta.eql(active_location, removal.removed) or
                    !std.meta.eql(current_active, active_location))
                {
                    return error.StaleTabRemoval;
                }

                const active = try handler.exactTab(active_location);
                if (active.model.layout.currentRevision() != removal.active_layout_revision) {
                    return error.StaleTabRemoval;
                }
            },
        }
    }

    fn exactTab(handler: *const DeliverTabRemovalHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabRemoval;
        if (!std.meta.eql(tab.location, location)) {
            return error.StaleTabRemoval;
        }

        return tab;
    }
};

const Event = union(enum) {
    retire_tab_requests: schema.TabLocation,
    clear_graphics: schema.PaneId,
    graphics_visibility: struct {
        pane_id: schema.PaneId,
        visible: bool,
    },
    synchronize_active_resources,
    tab_snapshot_pending,
    request_tab_snapshot: schema.TabLocation,
    forget_workspace: schema.WorkspaceLocation,
    request_workspace: schema.WorkspaceId,
};

const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
    tab_snapshot,
    workspace_handoff,
};

const TestingModel = struct {
    model: *client_model.Model,
    removed: schema.TabLocation,
    successor: schema.TabLocation,
    removed_root: schema.PaneId,
    removed_sibling: schema.PaneId,
    successor_root: schema.PaneId,

    fn init(with_successor: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const removed: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const successor: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const removed_root: schema.PaneId = @enumFromInt(1);
        const removed_sibling: schema.PaneId = @enumFromInt(2);
        const successor_root: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(.{ .pane_id = removed_root, .location = removed, .size = .{ .cols = 40, .rows = 10 } });
        try model.workspace.active().?.model.split(.{ .existing_pane = removed_root, .new_pane = removed_sibling, .location = removed, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
        if (!model.workspace.active().?.model.focusPane(removed_root)) {
            return error.RemovedFocusNotRestored;
        }

        const root = model.workspace.findPane(removed_root).?;
        root.input_modes.bracketed_paste = true;
        root.input_modes.focus_events = true;
        _ = model.beginPanePaste().?;
        _ = model.syncReportedPaneFocus().?;

        if (with_successor) {
            const tab = try model.workspace.addCreated(.{
                .location = successor,
                .position = 1,
                .label = "successor",
                .root_pane_id = successor_root,
            }, .{ .cols = 40, .rows = 10 });
            tab.model.find(successor_root).?.attached = false;
            if (!model.workspace.select(removed.tab_id)) {
                return error.RemovedTabNotRestored;
            }
        }

        return .{
            .model = model,
            .removed = removed,
            .successor = successor,
            .removed_root = removed_root,
            .removed_sibling = removed_sibling,
            .successor_root = successor_root,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn removeActive(testing: *TestingModel) !client_model.TabRemovalCommit {
        return testing.model.removeTab(.{
            .location = testing.removed,
            .workspace_removed = false,
        });
    }

    fn removeInactive(testing: *TestingModel) !client_model.TabRemovalCommit {
        return testing.model.removeTab(.{
            .location = testing.successor,
            .workspace_removed = false,
        });
    }

    fn removeWorkspace(testing: *TestingModel) !client_model.TabRemovalCommit {
        return testing.model.removeTab(.{
            .location = testing.removed,
            .workspace_removed = true,
        });
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    commit: client_model.TabRemovalCommit,
    events: [16]Event = undefined,
    event_count: usize = 0,
    snapshot_pending: bool = false,
    committed_state_observed: bool = true,
    pane_authorities_released: bool = true,
    focus_retired_before_activation: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .retire_tab_requests = retireTabRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .tab_snapshot_pending = tabSnapshotPending,
            .request_tab_snapshot = requestTabSnapshot,
            .forget_workspace = forgetWorkspace,
            .request_workspace = requestWorkspace,
        };
    }

    fn retireTabRequests(context: *anyopaque, location: schema.TabLocation) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .retire_tab_requests = location });
    }

    fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .clear_graphics = pane_id });
        if (capture.model.panePasteSession()) |session| {
            capture.pane_authorities_released = capture.pane_authorities_released and session.pane_id != pane_id;
        }
        if (capture.model.reportedPaneFocus()) |reported| {
            capture.pane_authorities_released = capture.pane_authorities_released and reported.pane_id != pane_id;
        }
    }

    fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .graphics_visibility = .{
            .pane_id = pane_id,
            .visible = visible,
        } });
        capture.focus_retired_before_activation = capture.focus_retired_before_activation and
            capture.model.reportedPaneFocus() == null;
        if (capture.failure == .graphics_visibility) {
            return error.GraphicsVisibilityFailed;
        }
    }

    fn synchronizeActiveResources(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.synchronize_active_resources);
        capture.focus_retired_before_activation = capture.focus_retired_before_activation and
            capture.model.reportedPaneFocus() == null;
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSynchronizationFailed;
        }
    }

    fn tabSnapshotPending(context: *anyopaque) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.tab_snapshot_pending);

        return capture.snapshot_pending;
    }

    fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .request_tab_snapshot = location });
        if (capture.failure == .tab_snapshot) {
            return error.TabSnapshotRequestFailed;
        }
    }

    fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .forget_workspace = workspace });
    }

    fn requestWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .request_workspace = workspace });
        if (capture.failure == .workspace_handoff) {
            return error.WorkspaceHandoffFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.committed_state_observed = capture.committed_state_observed and capture.observesCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observesCommit(capture: *const EffectsCapture) bool {
        const version = capture.model.version();
        return switch (capture.commit) {
            .stale => |stale| version.workspace == stale.workspace_revision and
                version.tabs == stale.tabs_revision and
                version.active_tab == stale.active_tab_revision and
                version.panes == stale.panes_revision and
                version.copy == stale.copy_revision,
            .removed => |removal| observed: {
                if (capture.model.workspace.find(removal.removed.tab_id) != null or
                    version.workspace != removal.workspace_revision or
                    version.tabs != removal.tabs_revision or
                    version.active_tab != removal.active_tab_revision or
                    version.panes != removal.panes_revision or
                    version.copy != removal.copy_revision)
                {
                    break :observed false;
                }

                if (removal.active) |location| {
                    const active = capture.model.workspace.find(location.tab_id) orelse break :observed false;
                    break :observed std.meta.eql(active.location, location) and
                        active.model.layout.currentRevision() == removal.active_layout_revision;
                }

                break :observed capture.model.workspace.workspace == null and removal.active_layout_revision == 0;
            },
        };
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverTabRemovalHandler {
    return .{
        .model = testing.model,
        .effects = capture.effects(),
    };
}

fn captureFor(testing: *TestingModel, commit: client_model.TabRemovalCommit) EffectsCapture {
    return .{
        .model = testing.model,
        .commit = commit,
    };
}

test "DeliverTabRemovalHandler releases an active tab before activating its successor" {
    var testing = try TestingModel.init(true);
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
    var testing = try TestingModel.init(true);
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
    var testing = try TestingModel.init(true);
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
    var exit_testing = try TestingModel.init(false);
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

    var handoff_testing = try TestingModel.init(false);
    defer handoff_testing.deinit();
    const handoff_commit = try handoff_testing.removeWorkspace();
    var handoff_capture = captureFor(&handoff_testing, handoff_commit);
    var handoff_handler = deliveryHandler(&handoff_testing, &handoff_capture);
    const previous: schema.WorkspaceId = @enumFromInt(9);

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
    var tab_testing = try TestingModel.init(true);
    defer tab_testing.deinit();
    const missing: schema.TabLocation = .{
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

    var workspace_testing = try TestingModel.init(true);
    defer workspace_testing.deinit();
    const foreign: schema.TabLocation = .{
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
    var testing = try TestingModel.init(true);
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
    var identity_testing = try TestingModel.init(true);
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

    var layout_testing = try TestingModel.init(true);
    defer layout_testing.deinit();
    const layout_commit = try layout_testing.removeActive();
    var layout_capture = captureFor(&layout_testing, layout_commit);
    var layout_handler = deliveryHandler(&layout_testing, &layout_capture);
    layout_testing.model.workspace.active().?.model.setPaneGaps(false);

    try std.testing.expectError(error.StaleTabRemoval, layout_handler.execute(layout_commit, null));
    try std.testing.expectEqual(@as(usize, 0), layout_capture.event_count);

    var pane_testing = try TestingModel.init(true);
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
    var tab_testing = try TestingModel.init(true);
    defer tab_testing.deinit();
    const missing: schema.TabLocation = .{
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

    var workspace_testing = try TestingModel.init(true);
    defer workspace_testing.deinit();
    const foreign: schema.TabLocation = .{
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
    var visibility_testing = try TestingModel.init(true);
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

    var resources_testing = try TestingModel.init(true);
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

    var snapshot_testing = try TestingModel.init(true);
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
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const commit = try testing.removeWorkspace();
    var capture = captureFor(&testing, commit);
    capture.failure = .workspace_handoff;
    var handler = deliveryHandler(&testing, &capture);
    const previous: schema.WorkspaceId = @enumFromInt(9);

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
