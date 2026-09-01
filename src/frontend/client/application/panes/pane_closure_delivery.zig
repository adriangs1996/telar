//! Application policy for delivering disposable client resources after one
//! committed pane exit.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const pane_resource_release = @import("pane_resource_release.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Effects = struct {
    context: *anyopaque,
    ignore_attachment: *const fn (*anyopaque, schema.PaneId) void,
    complete_close: *const fn (*anyopaque, schema.PaneId) void,
    clear_pane_graphics: *const fn (*anyopaque, schema.PaneId) void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
    active_geometry_area: *const fn (*anyopaque) core.ui.Rect,
};

pub const DeliverPaneClosureHandler = struct {
    model: *client_model.Model,
    geometry_effects: pane_geometry_delivery.OfferEffects,
    effects: Effects,

    /// Validates one exact pane-exit commit before retiring request and pane
    /// resources, then repairs active focus and geometry when required.
    ///
    /// ```zig
    /// try handler.execute(exit);
    /// ```
    pub fn execute(handler: *DeliverPaneClosureHandler, exit: client_model.PaneExit) !void {
        try handler.validate(exit);

        const pane_id = switch (exit) {
            .retired => |retirement| retirement.pane_id,
            .stale => |stale| stale.pane_id,
        };
        handler.effects.ignore_attachment(handler.effects.context, pane_id);
        handler.effects.complete_close(handler.effects.context, pane_id);

        var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
            .model = handler.model,
            .effects = .{
                .context = handler.effects.context,
                .clear_graphics = handler.effects.clear_pane_graphics,
            },
        };
        _ = release_pane.execute(pane_id);

        const retirement = switch (exit) {
            .retired => |retirement| retirement,
            .stale => return,
        };
        if (!retirement.active) {
            return;
        }

        handler.effects.invalidate_graphics_placements(handler.effects.context);
        try handler.effects.synchronize_active_resources(handler.effects.context);
        if (retirement.tab_empty) {
            return;
        }

        const tab = try handler.exactTab(retirement.location);
        const area = handler.effects.active_geometry_area(handler.effects.context);
        var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
            .effects = handler.geometry_effects,
        };
        _ = try offer_geometry.execute(&tab.model, area);
    }

    fn validate(handler: *const DeliverPaneClosureHandler, exit: client_model.PaneExit) !void {
        const version = handler.model.version();
        switch (exit) {
            .retired => |retirement| {
                const tab = try handler.exactTab(retirement.location);
                const active = handler.model.workspace.activeConst();
                const tab_active = active != null and std.meta.eql(active.?.location, retirement.location);
                if (version.workspace != retirement.workspace_revision or
                    version.tabs != retirement.tabs_revision or
                    version.active_tab != retirement.active_tab_revision or
                    version.panes != retirement.panes_revision or
                    tab.model.layout.currentRevision() != retirement.layout_revision or
                    tab_active != retirement.active or
                    (tab.model.pane_count == 0) != retirement.tab_empty or
                    handler.model.workspace.tabForPaneConst(retirement.pane_id) != null)
                {
                    return error.StalePaneExit;
                }
            },
            .stale => |stale| {
                if (version.workspace != stale.workspace_revision or
                    version.tabs != stale.tabs_revision or
                    version.active_tab != stale.active_tab_revision or
                    version.panes != stale.panes_revision or
                    handler.model.workspace.tabForPaneConst(stale.pane_id) != null)
                {
                    return error.StalePaneExit;
                }
            },
        }
    }

    fn exactTab(handler: *const DeliverPaneClosureHandler, location: schema.TabLocation) !*tabs_mod.Tab {
        const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneExit;
        if (!std.meta.eql(tab.location, location)) {
            return error.StalePaneExit;
        }

        return tab;
    }
};

const Event = union(enum) {
    ignore_attachment: schema.PaneId,
    complete_close: schema.PaneId,
    clear_graphics: schema.PaneId,
    invalidate_placements,
    synchronize_active_resources,
    active_geometry_area,
    resize: schema.PaneId,
};

const Failure = enum {
    none,
    active_resources,
    resize,
};

const TestingModel = struct {
    model: *client_model.Model,
    active: schema.TabLocation,
    inactive: schema.TabLocation,
    first: schema.PaneId,
    second: schema.PaneId,
    inactive_pane: schema.PaneId,
    area: core.ui.Rect,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const active: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const inactive: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const first: schema.PaneId = @enumFromInt(1);
        const second: schema.PaneId = @enumFromInt(2);
        const inactive_pane: schema.PaneId = @enumFromInt(3);
        const area: core.ui.Rect = .{ .w = 40, .h = 10 };
        try model.workspace.bootstrap(first, active, .{ .cols = 40, .rows = 10 });
        try model.workspace.active().?.model.split(first, second, active, .horizontal, area);
        _ = try model.workspace.addCreated(.{
            .location = inactive,
            .position = 1,
            .label = "inactive",
            .root_pane_id = inactive_pane,
        }, .{ .cols = 40, .rows = 10 });
        if (!model.workspace.select(active.tab_id)) {
            return error.ActiveTabNotRestored;
        }

        return .{
            .model = model,
            .active = active,
            .inactive = inactive,
            .first = first,
            .second = second,
            .inactive_pane = inactive_pane,
            .area = area,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    exit: client_model.PaneExit,
    events: [8]Event = undefined,
    event_count: usize = 0,
    committed_state_observed: bool = true,
    geometry_area: core.ui.Rect = .{ .w = 40, .h = 10 },
    delivered_resize: ?schema.PaneResize = null,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .ignore_attachment = ignoreAttachment,
            .complete_close = completeClose,
            .clear_pane_graphics = clearPaneGraphics,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .synchronize_active_resources = synchronizeActiveResources,
            .active_geometry_area = activeGeometryArea,
        };
    }

    fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
        return .{
            .context = capture,
            .deliver_resize = deliverResize,
        };
    }

    fn ignoreAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .ignore_attachment = pane_id });
    }

    fn completeClose(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .complete_close = pane_id });
    }

    fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .clear_graphics = pane_id });
    }

    fn invalidateGraphicsPlacements(context: *anyopaque) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.invalidate_placements);
    }

    fn synchronizeActiveResources(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSynchronizationFailed;
        }
    }

    fn activeGeometryArea(context: *anyopaque) core.ui.Rect {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.active_geometry_area);

        return capture.geometry_area;
    }

    fn deliverResize(context: *anyopaque, resize: schema.PaneResize) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.{ .resize = resize.pane_id });
        capture.delivered_resize = resize;
        if (capture.failure == .resize) {
            return error.PaneResizeDeliveryFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.committed_state_observed = capture.committed_state_observed and capture.observesCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observesCommit(capture: *const EffectsCapture) bool {
        const version = capture.model.version();
        return switch (capture.exit) {
            .retired => |retirement| observed: {
                const tab = capture.model.workspace.find(retirement.location.tab_id) orelse break :observed false;
                const active = capture.model.workspace.activeConst();
                const tab_active = active != null and std.meta.eql(active.?.location, retirement.location);

                break :observed std.meta.eql(tab.location, retirement.location) and
                    capture.model.workspace.tabForPaneConst(retirement.pane_id) == null and
                    tab.model.layout.currentRevision() == retirement.layout_revision and
                    (tab.model.pane_count == 0) == retirement.tab_empty and
                    tab_active == retirement.active and
                    version.workspace == retirement.workspace_revision and
                    version.tabs == retirement.tabs_revision and
                    version.active_tab == retirement.active_tab_revision and
                    version.panes == retirement.panes_revision;
            },
            .stale => |stale| capture.model.workspace.tabForPaneConst(stale.pane_id) == null and
                version.workspace == stale.workspace_revision and
                version.tabs == stale.tabs_revision and
                version.active_tab == stale.active_tab_revision and
                version.panes == stale.panes_revision,
        };
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn deliveryHandler(testing: *TestingModel, capture: *EffectsCapture) DeliverPaneClosureHandler {
    return .{
        .model = testing.model,
        .geometry_effects = capture.geometryEffects(),
        .effects = capture.effects(),
    };
}

test "DeliverPaneClosureHandler releases an active exit before focus and geometry repair" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.beginPanePaste().?;
    _ = testing.model.syncReportedPaneFocus().?;
    const exit = testing.model.retirePane(testing.second);
    var capture: EffectsCapture = .{
        .model = testing.model,
        .exit = exit,
        .geometry_area = .{ .w = 30, .h = 8 },
    };
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(exit);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = testing.second },
        .{ .complete_close = testing.second },
        .{ .clear_graphics = testing.second },
        .invalidate_placements,
        .synchronize_active_resources,
        .active_geometry_area,
        .{ .resize = testing.first },
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expectEqualDeep(
        testing.model.workspace.active().?.model.contentSize(testing.first, capture.geometry_area).?,
        capture.delivered_resize.?.size,
    );
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
}

test "DeliverPaneClosureHandler limits inactive and stale exits to idempotent cleanup" {
    var inactive_testing = try TestingModel.init();
    defer inactive_testing.deinit();
    const inactive_exit = inactive_testing.model.retirePane(inactive_testing.inactive_pane);
    var inactive_capture: EffectsCapture = .{
        .model = inactive_testing.model,
        .exit = inactive_exit,
    };
    var inactive_handler = deliveryHandler(&inactive_testing, &inactive_capture);

    try inactive_handler.execute(inactive_exit);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = inactive_testing.inactive_pane },
        .{ .complete_close = inactive_testing.inactive_pane },
        .{ .clear_graphics = inactive_testing.inactive_pane },
    }, inactive_capture.eventSlice());
    try std.testing.expect(inactive_capture.committed_state_observed);

    var stale_testing = try TestingModel.init();
    defer stale_testing.deinit();
    const missing: schema.PaneId = @enumFromInt(99);
    const stale_exit = stale_testing.model.retirePane(missing);
    var stale_capture: EffectsCapture = .{ .model = stale_testing.model, .exit = stale_exit };
    var stale_handler = deliveryHandler(&stale_testing, &stale_capture);

    try stale_handler.execute(stale_exit);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = missing },
        .{ .complete_close = missing },
        .{ .clear_graphics = missing },
    }, stale_capture.eventSlice());
    try std.testing.expect(stale_capture.committed_state_observed);
}

test "DeliverPaneClosureHandler skips geometry after the active tab becomes empty" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.retirePane(testing.second);
    const exit = testing.model.retirePane(testing.first);
    var capture: EffectsCapture = .{ .model = testing.model, .exit = exit };
    var handler = deliveryHandler(&testing, &capture);

    try handler.execute(exit);

    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = testing.first },
        .{ .complete_close = testing.first },
        .{ .clear_graphics = testing.first },
        .invalidate_placements,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneClosureHandler rejects altered active commits before cleanup" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const exit = testing.model.retirePane(testing.second);
    var capture: EffectsCapture = .{ .model = testing.model, .exit = exit };
    var handler = deliveryHandler(&testing, &capture);

    var wrong_revision = exit;
    wrong_revision.retired.panes_revision -%= 1;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_revision));

    wrong_revision = exit;
    wrong_revision.retired.workspace_revision -%= 1;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_revision));

    wrong_revision = exit;
    wrong_revision.retired.tabs_revision -%= 1;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_revision));

    wrong_revision = exit;
    wrong_revision.retired.active_tab_revision -%= 1;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_revision));

    var wrong_layout = exit;
    wrong_layout.retired.layout_revision -%= 1;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_layout));

    var wrong_activity = exit;
    wrong_activity.retired.active = false;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_activity));

    var wrong_emptiness = exit;
    wrong_emptiness.retired.tab_empty = true;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_emptiness));

    var wrong_location = exit;
    wrong_location.retired.location = testing.inactive;
    try std.testing.expectError(error.StalePaneExit, handler.execute(wrong_location));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneClosureHandler catches inactive layout ABA and represented stale identities" {
    var inactive_testing = try TestingModel.init();
    defer inactive_testing.deinit();
    const inactive_exit = inactive_testing.model.retirePane(inactive_testing.inactive_pane);
    var inactive_capture: EffectsCapture = .{
        .model = inactive_testing.model,
        .exit = inactive_exit,
    };
    var inactive_handler = deliveryHandler(&inactive_testing, &inactive_capture);
    const inactive_tab = inactive_testing.model.workspace.find(inactive_testing.inactive.tab_id).?;
    try std.testing.expect(inactive_tab.model.layout.setPaneGaps(false));

    try std.testing.expectError(error.StalePaneExit, inactive_handler.execute(inactive_exit));
    try std.testing.expectEqual(@as(usize, 0), inactive_capture.event_count);

    var stale_testing = try TestingModel.init();
    defer stale_testing.deinit();
    const missing: schema.PaneId = @enumFromInt(99);
    const stale_exit = stale_testing.model.retirePane(missing);
    var stale_capture: EffectsCapture = .{ .model = stale_testing.model, .exit = stale_exit };
    var stale_handler = deliveryHandler(&stale_testing, &stale_capture);
    var wrong_stale_revision = stale_exit;
    wrong_stale_revision.stale.workspace_revision -%= 1;

    try std.testing.expectError(error.StalePaneExit, stale_handler.execute(wrong_stale_revision));
    try std.testing.expectEqual(@as(usize, 0), stale_capture.event_count);

    try stale_testing.model.workspace.active().?.model.split(
        stale_testing.second,
        missing,
        stale_testing.active,
        .horizontal,
        stale_testing.area,
    );

    try std.testing.expectError(error.StalePaneExit, stale_handler.execute(stale_exit));
    try std.testing.expectEqual(@as(usize, 0), stale_capture.event_count);
}

test "DeliverPaneClosureHandler preserves cleanup across active delivery failures" {
    var sync_testing = try TestingModel.init();
    defer sync_testing.deinit();
    const sync_exit = sync_testing.model.retirePane(sync_testing.second);
    var sync_capture: EffectsCapture = .{
        .model = sync_testing.model,
        .exit = sync_exit,
        .failure = .active_resources,
    };
    var sync_handler = deliveryHandler(&sync_testing, &sync_capture);

    try std.testing.expectError(
        error.ActiveResourceSynchronizationFailed,
        sync_handler.execute(sync_exit),
    );
    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = sync_testing.second },
        .{ .complete_close = sync_testing.second },
        .{ .clear_graphics = sync_testing.second },
        .invalidate_placements,
        .synchronize_active_resources,
    }, sync_capture.eventSlice());
    try std.testing.expect(sync_capture.committed_state_observed);

    var resize_testing = try TestingModel.init();
    defer resize_testing.deinit();
    const resize_exit = resize_testing.model.retirePane(resize_testing.second);
    var resize_capture: EffectsCapture = .{
        .model = resize_testing.model,
        .exit = resize_exit,
        .failure = .resize,
    };
    var resize_handler = deliveryHandler(&resize_testing, &resize_capture);

    try std.testing.expectError(error.PaneResizeDeliveryFailed, resize_handler.execute(resize_exit));
    try std.testing.expectEqualSlices(Event, &.{
        .{ .ignore_attachment = resize_testing.second },
        .{ .complete_close = resize_testing.second },
        .{ .clear_graphics = resize_testing.second },
        .invalidate_placements,
        .synchronize_active_resources,
        .active_geometry_area,
        .{ .resize = resize_testing.first },
    }, resize_capture.eventSlice());
    try std.testing.expect(resize_capture.committed_state_observed);
}
