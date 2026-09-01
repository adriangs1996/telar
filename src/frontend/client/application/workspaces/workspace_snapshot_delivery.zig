//! Application policy for delivering client resources after one canonical
//! workspace snapshot commit.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");
const pane_focus_reporting = @import("../panes/pane_focus_reporting.zig");
const pane_geometry_delivery = @import("../panes/pane_geometry_delivery.zig");
const pane_resource_release = @import("../panes/pane_resource_release.zig");

const schema = core.schema;
const ui = core.ui;

pub const Effects = struct {
    context: *anyopaque,
    ignore_tab_requests: *const fn (*anyopaque, schema.TabId) void,
    clear_pane_graphics: *const fn (*anyopaque, schema.PaneId) void,
    set_pane_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    tab_snapshot_pending: *const fn (*anyopaque) bool,
    request_tab_snapshot: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const DeliverWorkspaceSnapshotHandler = struct {
    model: *client_model.Model,
    area: ui.Rect,
    geometry_effects: pane_geometry_delivery.OfferEffects,
    effects: Effects,

    /// Validates one exact reconciliation before releasing retired resources,
    /// activating the canonical tab and repairing snapshot or geometry state.
    ///
    /// ```zig
    /// try handler.execute(&reconciliation);
    /// ```
    pub fn execute(handler: *DeliverWorkspaceSnapshotHandler, reconciliation: *const client_model.WorkspaceReconciliation) !void {
        try handler.validate(reconciliation);

        for (reconciliation.removed_tabs.slice()) |location| {
            handler.effects.ignore_tab_requests(handler.effects.context, location.tab_id);
        }

        var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
            .model = handler.model,
            .effects = .{
                .context = handler.effects.context,
                .clear_graphics = handler.effects.clear_pane_graphics,
            },
        };
        for (reconciliation.removed_panes.slice()) |pane_id| {
            _ = release_pane.execute(pane_id);
        }

        const active = handler.model.workspace.active() orelse return error.StaleWorkspaceReconciliation;
        if (reconciliation.active_tab_changed) {
            var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
                .model = handler.model,
            };
            _ = retire_focus.execute();

            var panes = active.model.paneIterator();
            while (panes.next()) |pane| {
                try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
            }

            try handler.effects.synchronize_active_resources(handler.effects.context);
        }

        if (handler.effects.tab_snapshot_pending(handler.effects.context)) {
            return;
        }

        if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
            try handler.effects.request_tab_snapshot(handler.effects.context, reconciliation.active);
            return;
        }

        var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
            .effects = handler.geometry_effects,
        };
        _ = try offer_geometry.execute(&active.model, handler.area);
    }

    fn validate(handler: *const DeliverWorkspaceSnapshotHandler, reconciliation: *const client_model.WorkspaceReconciliation) !void {
        const active = handler.model.workspace.activeConst() orelse return error.StaleWorkspaceReconciliation;
        const version = handler.model.version();
        if (!std.meta.eql(active.location, reconciliation.active) or
            reconciliation.active_tab_changed != !std.meta.eql(reconciliation.previous_active, reconciliation.active) or
            active.snapshot_loaded != reconciliation.active_snapshot_loaded or
            version.workspace != reconciliation.workspace_revision or
            version.tabs != reconciliation.tabs_revision or
            version.active_tab != reconciliation.active_tab_revision or
            version.panes != reconciliation.panes_revision)
        {
            return error.StaleWorkspaceReconciliation;
        }
    }
};

const Event = union(enum) {
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

const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
    tab_snapshot,
    resize,
};

const TestingModel = struct {
    model: *client_model.Model,
    workspace: schema.WorkspaceLocation,
    first: schema.TabLocation,
    second: schema.TabLocation,
    first_pane: schema.PaneId,
    second_pane: schema.PaneId,
    tabs: [1]client_model.WorkspaceTabInput,

    fn init(two_tabs: bool) !TestingModel {
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
        try model.workspace.bootstrap(first_pane, first, .{ .cols = 20, .rows = 5 });
        if (two_tabs) {
            _ = try model.workspace.addCreated(.{
                .location = second,
                .position = 1,
                .label = "logs",
                .root_pane_id = second_pane,
            }, .{ .cols = 20, .rows = 5 });
        }

        return .{
            .model = model,
            .workspace = workspace,
            .first = first,
            .second = second,
            .first_pane = first_pane,
            .second_pane = second_pane,
            .tabs = .{.{
                .tab_id = first.tab_id,
                .pane_count = 1,
                .label = "main",
            }},
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn snapshot(testing: *const TestingModel) client_model.WorkspaceSnapshot {
        return .{
            .workspace = testing.workspace,
            .name = "main",
            .tabs = &testing.tabs,
        };
    }

    fn reconcile(testing: *TestingModel) !client_model.WorkspaceReconciliation {
        return testing.model.reconcileWorkspace(testing.snapshot());
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    reconciliation: *const client_model.WorkspaceReconciliation,
    events: [10]Event = undefined,
    event_count: usize = 0,
    pending_snapshot: bool = false,
    delivered_resize: ?schema.PaneResize = null,
    committed_state_observed: bool = true,
    resources_released_before_graphics: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .ignore_tab_requests = ignoreTabRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .tab_snapshot_pending = tabSnapshotPending,
            .request_tab_snapshot = requestTabSnapshot,
        };
    }

    fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
        return .{
            .context = capture,
            .deliver_resize = deliverResize,
        };
    }

    fn ignoreTabRequests(raw_context: *anyopaque, tab_id: schema.TabId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .ignore_tab = tab_id });
    }

    fn clearPaneGraphics(raw_context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .clear_graphics = pane_id });
        capture.resources_released_before_graphics = capture.resources_released_before_graphics and
            !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
    }

    fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .set_graphics_visible = .{
            .pane_id = pane_id,
            .visible = visible,
        } });
        if (capture.failure == .graphics_visibility) {
            return error.GraphicsVisibilityFailed;
        }
    }

    fn synchronizeActiveResources(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSyncFailed;
        }
    }

    fn tabSnapshotPending(raw_context: *anyopaque) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.tab_snapshot_pending);

        return capture.pending_snapshot;
    }

    fn requestTabSnapshot(raw_context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .request_tab_snapshot = location });
        if (capture.failure == .tab_snapshot) {
            return error.TabSnapshotRequestFailed;
        }
    }

    fn deliverResize(raw_context: *anyopaque, resize: schema.PaneResize) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .resize = resize.pane_id });
        capture.delivered_resize = resize;
        if (capture.failure == .resize) {
            return error.PaneResizeFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.observeCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeCommit(capture: *EffectsCapture) void {
        const active = capture.model.workspace.activeConst() orelse {
            capture.committed_state_observed = false;
            return;
        };
        const version = capture.model.version();

        capture.committed_state_observed = capture.committed_state_observed and
            std.meta.eql(active.location, capture.reconciliation.active) and
            active.snapshot_loaded == capture.reconciliation.active_snapshot_loaded and
            version.workspace == capture.reconciliation.workspace_revision and
            version.tabs == capture.reconciliation.tabs_revision and
            version.active_tab == capture.reconciliation.active_tab_revision and
            version.panes == capture.reconciliation.panes_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
