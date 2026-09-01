//! Application policy for delivering client resources after one committed pane
//! split confirmation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Effects = struct {
    context: *anyopaque,
    detach_pane: *const fn (*anyopaque, schema.PaneId) anyerror!void,
    set_pane_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    workspace_snapshot_pending: *const fn (*anyopaque) bool,
    request_workspace_snapshot: *const fn (*anyopaque, schema.WorkspaceLocation) anyerror!void,
};

pub const DeliverPaneSplitConfirmationHandler = struct {
    model: *client_model.Model,
    geometry_effects: pane_geometry_delivery.OfferEffects,
    effects: Effects,

    /// Validates one exact split commit before applying the resource policy
    /// selected by its active, inactive or stale disposition.
    ///
    /// ```zig
    /// try handler.execute(commit);
    /// ```
    pub fn execute(handler: *DeliverPaneSplitConfirmationHandler, commit: client_model.PaneSplitCommit) !void {
        try handler.validate(commit);

        switch (commit.disposition) {
            .active => {
                const tab = try handler.exactTab(commit.location);
                var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
                    .effects = handler.geometry_effects,
                };
                _ = try offer_geometry.execute(&tab.model, commit.area);
                try handler.effects.synchronize_active_resources(handler.effects.context);
            },
            .inactive => {
                try handler.effects.detach_pane(handler.effects.context, commit.pane_id);
                try handler.effects.set_pane_graphics_visible(handler.effects.context, commit.pane_id, false);
            },
            .stale => {
                try handler.effects.detach_pane(handler.effects.context, commit.pane_id);
                const workspace = handler.model.workspace.workspace orelse return;
                if (!std.meta.eql(workspace, commit.location.workspace)) {
                    return;
                }
                if (handler.effects.workspace_snapshot_pending(handler.effects.context)) {
                    return;
                }

                try handler.effects.request_workspace_snapshot(handler.effects.context, workspace);
            },
        }
    }

    fn validate(handler: *const DeliverPaneSplitConfirmationHandler, commit: client_model.PaneSplitCommit) !void {
        const version = handler.model.version();
        if (version.workspace != commit.workspace_revision or
            version.tabs != commit.tabs_revision or
            version.active_tab != commit.active_tab_revision or
            version.panes != commit.panes_revision)
        {
            return error.StalePaneSplitConfirmation;
        }

        switch (commit.disposition) {
            .active, .inactive => {
                const tab = try handler.exactTab(commit.location);
                const pane = tab.model.find(commit.pane_id) orelse return error.StalePaneSplitConfirmation;
                const active = handler.model.workspace.activeConst();
                const tab_active = active != null and std.meta.eql(active.?.location, commit.location);
                if (tab_active != (commit.disposition == .active) or
                    pane.attached != tab_active or
                    !std.meta.eql(pane.location, commit.location) or
                    tab.model.layout.currentRevision() != commit.layout_revision or
                    (commit.disposition == .inactive and commit.change != .unchanged))
                {
                    return error.StalePaneSplitConfirmation;
                }
            },
            .stale => {
                if (commit.change != .unchanged or
                    commit.layout_revision != 0 or
                    handler.model.workspace.findPane(commit.pane_id) != null)
                {
                    return error.StalePaneSplitConfirmation;
                }

                const workspace = handler.model.workspace.workspace orelse return;
                if (std.meta.eql(workspace, commit.location.workspace) and
                    handler.model.workspace.find(commit.location.tab_id) != null)
                {
                    return error.StalePaneSplitConfirmation;
                }
            },
        }
    }

    fn exactTab(handler: *const DeliverPaneSplitConfirmationHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneSplitConfirmation;
        if (!std.meta.eql(tab.location, location)) {
            return error.StalePaneSplitConfirmation;
        }

        return tab;
    }
};

const Event = union(enum) {
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

const Failure = enum {
    none,
    resize,
    active_resources,
    detach,
    graphics_visibility,
    workspace_snapshot,
};

const TestingModel = struct {
    model: *client_model.Model,
    first: schema.TabLocation,
    second: schema.TabLocation,
    first_pane: schema.PaneId,
    second_pane: schema.PaneId,
    created_pane: schema.PaneId,
    area: core.ui.Rect,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const first_pane: schema.PaneId = @enumFromInt(1);
        const second_pane: schema.PaneId = @enumFromInt(2);
        const created_pane: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(first_pane, first, .{ .cols = 40, .rows = 10 });

        return .{
            .model = model,
            .first = first,
            .second = second,
            .first_pane = first_pane,
            .second_pane = second_pane,
            .created_pane = created_pane,
            .area = .{ .w = 40, .h = 10 },
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn activeCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
        return testing.model.commitPaneSplit(testing.command());
    }

    fn inactiveCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
        try testing.addSecondTab();

        return testing.model.commitPaneSplit(testing.command());
    }

    fn staleCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
        try testing.addSecondTab();
        if (!testing.model.workspace.remove(testing.first.tab_id)) {
            return error.MissingTab;
        }

        return testing.model.commitPaneSplit(testing.command());
    }

    fn foreignWorkspaceCommit(testing: *TestingModel) !client_model.PaneSplitCommit {
        const foreign: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = testing.second.tab_id,
        };
        try testing.model.workspace.replaceWithRoot(.{
            .pane_id = testing.second_pane,
            .location = foreign,
            .size = .{ .cols = 40, .rows = 10 },
        });

        return testing.model.commitPaneSplit(testing.command());
    }

    fn addSecondTab(testing: *TestingModel) !void {
        _ = try testing.model.workspace.addCreated(.{
            .location = testing.second,
            .position = 1,
            .label = "second",
            .root_pane_id = testing.second_pane,
        }, .{ .cols = 40, .rows = 10 });
    }

    fn command(testing: *const TestingModel) client_model.CommitPaneSplit {
        return .{
            .split = .{
                .target_pane = testing.first_pane,
                .location = testing.first,
                .axis = .horizontal,
                .area = testing.area,
            },
            .new_pane = testing.created_pane,
        };
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    commit: client_model.PaneSplitCommit,
    snapshot_pending: bool = false,
    events: [8]Event = undefined,
    event_count: usize = 0,
    committed_state_observed: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .detach_pane = detachPane,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .workspace_snapshot_pending = workspaceSnapshotPending,
            .request_workspace_snapshot = requestWorkspaceSnapshot,
        };
    }

    fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
        return .{
            .context = capture,
            .deliver_resize = deliverResize,
        };
    }

    fn deliverResize(raw_context: *anyopaque, resize: schema.PaneResize) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .resize = resize.pane_id });
        if (capture.failure == .resize) {
            return error.PaneResizeFailed;
        }
    }

    fn synchronizeActiveResources(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSyncFailed;
        }
    }

    fn detachPane(raw_context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .detach = pane_id });
        if (capture.failure == .detach) {
            return error.PaneDetachFailed;
        }
    }

    fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .graphics_visibility = .{
            .pane_id = pane_id,
            .visible = visible,
        } });
        if (capture.failure == .graphics_visibility) {
            return error.GraphicsVisibilityFailed;
        }
    }

    fn workspaceSnapshotPending(raw_context: *anyopaque) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.workspace_snapshot_pending);

        return capture.snapshot_pending;
    }

    fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .request_workspace_snapshot = workspace });
        if (capture.failure == .workspace_snapshot) {
            return error.WorkspaceSnapshotRequestFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.observeCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeCommit(capture: *EffectsCapture) void {
        const version = capture.model.version();
        capture.committed_state_observed = capture.committed_state_observed and
            version.workspace == capture.commit.workspace_revision and
            version.tabs == capture.commit.tabs_revision and
            version.active_tab == capture.commit.active_tab_revision and
            version.panes == capture.commit.panes_revision;

        switch (capture.commit.disposition) {
            .active, .inactive => {
                const tab = capture.model.workspace.find(capture.commit.location.tab_id) orelse {
                    capture.committed_state_observed = false;
                    return;
                };
                const pane = tab.model.find(capture.commit.pane_id) orelse {
                    capture.committed_state_observed = false;
                    return;
                };
                capture.committed_state_observed = capture.committed_state_observed and
                    pane.attached == (capture.commit.disposition == .active) and
                    tab.model.layout.currentRevision() == capture.commit.layout_revision;
            },
            .stale => {
                capture.committed_state_observed = capture.committed_state_observed and
                    capture.model.workspace.findPane(capture.commit.pane_id) == null;
            },
        }
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
