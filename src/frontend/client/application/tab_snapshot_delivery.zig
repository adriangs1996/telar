//! Application policy for delivering client resources after one canonical tab
//! snapshot commit.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../model.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const pane_resource_release = @import("pane_resource_release.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const PaneAttachmentRequest = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    size: schema.TerminalSize,
};

pub const Effects = struct {
    context: *anyopaque,
    ignore_pane_requests: *const fn (*anyopaque, schema.PaneId) void,
    clear_pane_graphics: *const fn (*anyopaque, schema.PaneId) void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    attachment_pending: *const fn (*anyopaque, schema.PaneId) bool,
    request_attachment: *const fn (*anyopaque, PaneAttachmentRequest) anyerror!void,
};

pub const DeliverTabSnapshotHandler = struct {
    model: *client_model.Model,
    geometry_effects: pane_geometry_delivery.OfferEffects,
    effects: Effects,

    /// Validates one exact tab reconciliation before releasing retired panes,
    /// repairing active geometry and requesting each missing attachment once.
    ///
    /// ```zig
    /// try handler.execute(&reconciliation);
    /// ```
    pub fn execute(handler: *DeliverTabSnapshotHandler, reconciliation: *const client_model.TabReconciliation) !void {
        try handler.validate(reconciliation);

        var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
            .model = handler.model,
            .effects = .{
                .context = handler.effects.context,
                .clear_graphics = handler.effects.clear_pane_graphics,
            },
        };
        for (reconciliation.removed_panes.slice()) |pane_id| {
            handler.effects.ignore_pane_requests(handler.effects.context, pane_id);
            _ = release_pane.execute(pane_id);
        }

        if (!reconciliation.active) {
            return;
        }

        const tab = try handler.exactTab(reconciliation.location);
        try handler.effects.synchronize_active_resources(handler.effects.context);

        var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
            .effects = handler.geometry_effects,
        };
        _ = try offer_geometry.execute(&tab.model, reconciliation.area);

        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            if (pane.attached or handler.effects.attachment_pending(handler.effects.context, pane.id)) {
                continue;
            }

            const size = tab.model.contentSize(pane.id, reconciliation.area) orelse return error.PaneTooSmall;
            try handler.effects.request_attachment(handler.effects.context, .{
                .pane_id = pane.id,
                .location = reconciliation.location,
                .size = size,
            });
        }
    }

    fn validate(handler: *const DeliverTabSnapshotHandler, reconciliation: *const client_model.TabReconciliation) !void {
        const tab = try handler.exactTab(reconciliation.location);
        const active = handler.model.workspace.activeConst() orelse return error.StaleTabReconciliation;
        const version = handler.model.version();
        if (reconciliation.active != std.meta.eql(active.location, reconciliation.location) or
            tab.snapshot_loaded != reconciliation.snapshot_loaded or
            tab.model.layout.currentRevision() != reconciliation.layout_revision or
            version.workspace != reconciliation.workspace_revision or
            version.tabs != reconciliation.tabs_revision or
            version.active_tab != reconciliation.active_tab_revision or
            version.panes != reconciliation.panes_revision)
        {
            return error.StaleTabReconciliation;
        }
    }

    fn exactTab(handler: *const DeliverTabSnapshotHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabReconciliation;
        if (!std.meta.eql(tab.location, location)) {
            return error.StaleTabReconciliation;
        }

        return tab;
    }
};

const Event = union(enum) {
    ignore_pane: schema.PaneId,
    clear_graphics: schema.PaneId,
    synchronize_active_resources,
    resize: schema.PaneId,
    attachment_pending: schema.PaneId,
    request_attachment: schema.PaneId,
};

const Failure = enum {
    none,
    active_resources,
    resize,
    attachment,
};

const TestingModel = struct {
    model: *client_model.Model,
    target: schema.TabLocation,
    root: schema.PaneId,
    discovered: schema.PaneId,
    other_pane: schema.PaneId,
    many: [2]schema.PaneId,
    root_only: [1]schema.PaneId,

    fn init(target_active: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const target: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const other: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const root: schema.PaneId = @enumFromInt(1);
        const discovered: schema.PaneId = @enumFromInt(2);
        const other_pane: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(root, target, .{ .cols = 20, .rows = 5 });
        if (!target_active) {
            _ = try model.workspace.addCreated(.{
                .location = other,
                .position = 1,
                .label = "other",
                .root_pane_id = other_pane,
            }, .{ .cols = 20, .rows = 5 });
        }

        return .{
            .model = model,
            .target = target,
            .root = root,
            .discovered = discovered,
            .other_pane = other_pane,
            .many = .{ root, discovered },
            .root_only = .{root},
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn reconcileMany(testing: *TestingModel) !client_model.TabReconciliation {
        return testing.reconcile(&testing.many);
    }

    fn reconcileRoot(testing: *TestingModel) !client_model.TabReconciliation {
        return testing.reconcile(&testing.root_only);
    }

    fn reconcile(testing: *TestingModel, panes: []const schema.PaneId) !client_model.TabReconciliation {
        return testing.model.reconcileTab(.{
            .location = testing.target,
            .panes = panes,
        }, .{ .w = 40, .h = 10 });
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    reconciliation: *const client_model.TabReconciliation,
    pending_attachment: ?schema.PaneId = null,
    events: [10]Event = undefined,
    event_count: usize = 0,
    attachment: ?PaneAttachmentRequest = null,
    committed_state_observed: bool = true,
    resources_released_before_graphics: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .ignore_pane_requests = ignorePaneRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .synchronize_active_resources = synchronizeActiveResources,
            .attachment_pending = attachmentPending,
            .request_attachment = requestAttachment,
        };
    }

    fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
        return .{
            .context = capture,
            .deliver_resize = deliverResize,
        };
    }

    fn ignorePaneRequests(raw_context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .ignore_pane = pane_id });
    }

    fn clearPaneGraphics(raw_context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .clear_graphics = pane_id });
        capture.resources_released_before_graphics = capture.resources_released_before_graphics and
            !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
    }

    fn synchronizeActiveResources(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSyncFailed;
        }
    }

    fn deliverResize(raw_context: *anyopaque, resize: schema.PaneResize) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .resize = resize.pane_id });
        if (capture.failure == .resize) {
            return error.PaneResizeFailed;
        }
    }

    fn attachmentPending(raw_context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .attachment_pending = pane_id });

        return capture.pending_attachment == pane_id;
    }

    fn requestAttachment(raw_context: *anyopaque, request: PaneAttachmentRequest) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.{ .request_attachment = request.pane_id });
        capture.attachment = request;
        if (capture.failure == .attachment) {
            return error.AttachmentRequestFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.observeCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeCommit(capture: *EffectsCapture) void {
        const tab = capture.model.workspace.find(capture.reconciliation.location.tab_id) orelse {
            capture.committed_state_observed = false;
            return;
        };
        const active = capture.model.workspace.activeConst() orelse {
            capture.committed_state_observed = false;
            return;
        };
        const version = capture.model.version();

        capture.committed_state_observed = capture.committed_state_observed and
            std.meta.eql(tab.location, capture.reconciliation.location) and
            capture.reconciliation.active == std.meta.eql(active.location, tab.location) and
            tab.snapshot_loaded == capture.reconciliation.snapshot_loaded and
            tab.model.layout.currentRevision() == capture.reconciliation.layout_revision and
            version.workspace == capture.reconciliation.workspace_revision and
            version.tabs == capture.reconciliation.tabs_revision and
            version.active_tab == capture.reconciliation.active_tab_revision and
            version.panes == capture.reconciliation.panes_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn deliveryHandler(capture: *EffectsCapture) DeliverTabSnapshotHandler {
    return .{
        .model = capture.model,
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverTabSnapshotHandler synchronizes active resources before geometry and attachments" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
        .{ .request_attachment = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expectEqual(testing.discovered, capture.attachment.?.pane_id);
    try std.testing.expectEqualDeep(testing.target, capture.attachment.?.location);
    try std.testing.expect(capture.attachment.?.size.cols > 0);
    try std.testing.expect(capture.attachment.?.size.rows > 0);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler releases retired resources before active synchronization" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const all = [_]schema.PaneId{ testing.root, testing.discovered, testing.other_pane };
    _ = try testing.reconcile(&all);
    const tab = testing.model.workspace.find(testing.target.tab_id).?;
    try tab.model.markAttached(testing.discovered);
    try std.testing.expect(tab.model.focusPane(testing.discovered));
    const pane = tab.model.find(testing.discovered).?;
    pane.input_modes.bracketed_paste = true;
    pane.input_modes.focus_events = true;
    _ = testing.model.beginPanePaste().?;
    _ = testing.model.syncReportedPaneFocus().?;
    const reconciliation = try testing.reconcileRoot();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ignore_pane = testing.discovered },
        .{ .clear_graphics = testing.discovered },
        .{ .ignore_pane = testing.other_pane },
        .{ .clear_graphics = testing.other_pane },
        .synchronize_active_resources,
        .{ .resize = testing.root },
    }, capture.eventSlice());
    try std.testing.expect(capture.resources_released_before_graphics);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
}

test "DeliverTabSnapshotHandler preserves a pending attachment" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .pending_attachment = testing.discovered,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(?PaneAttachmentRequest, null), capture.attachment);
}

test "DeliverTabSnapshotHandler leaves inactive tab resources untouched" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    try use_case.execute(&reconciliation);

    try std.testing.expect(!reconciliation.active);
    try std.testing.expect(reconciliation.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().panes);
}

test "DeliverTabSnapshotHandler rejects stale topology layout and snapshot state" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
    };
    var use_case = deliveryHandler(&capture);

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    testing.model.panes_revision -%= 1;

    reconciliation.active = !reconciliation.active;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    reconciliation.active = !reconciliation.active;

    const tab = testing.model.workspace.find(testing.target.tab_id).?;
    tab.snapshot_loaded = false;
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));
    tab.snapshot_loaded = true;

    const focused = tab.model.layout.focused().?;
    const other = if (focused == testing.root) testing.discovered else testing.root;
    try std.testing.expect(tab.model.focusPane(other));
    try std.testing.expectError(error.StaleTabReconciliation, use_case.execute(&reconciliation));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverTabSnapshotHandler stops before geometry after active resource failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .active_resources,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.ActiveResourceSyncFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{.synchronize_active_resources}, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler stops before attachments after geometry failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .resize,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.PaneResizeFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverTabSnapshotHandler preserves earlier effects after attachment failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const reconciliation = try testing.reconcileMany();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .reconciliation = &reconciliation,
        .failure = .attachment,
    };
    var use_case = deliveryHandler(&capture);

    try std.testing.expectError(error.AttachmentRequestFailed, use_case.execute(&reconciliation));

    try std.testing.expectEqualDeep(&[_]Event{
        .synchronize_active_resources,
        .{ .resize = testing.root },
        .{ .attachment_pending = testing.discovered },
        .{ .request_attachment = testing.discovered },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
