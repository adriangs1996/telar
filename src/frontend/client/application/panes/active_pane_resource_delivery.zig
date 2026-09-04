//! Application policy for synchronizing resources derived from the client's
//! active focused pane.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const attachments = @import("../../../attachments/root.zig");
const client_model = @import("../../model/root.zig");

const ui = core.ui;

pub const Effects = struct {
    context: *anyopaque,
    sync_attachment_target: *const fn (*anyopaque, ?attachments.Target) ?ui.Rect,
    sync_focus_reporting: *const fn (*anyopaque) anyerror!void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    offer_pane_geometry: *const fn (*anyopaque, ui.Rect) anyerror!void,
    acknowledge_agent: *const fn (*anyopaque, agents.AgentKey) anyerror!void,
};

pub const DeliverActivePaneResourcesHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Acknowledges a focused `done` agent, then reconciles only the focused
    /// attachment shelf and re-offers geometry when its visibility changes
    /// the workbench.
    ///
    /// ```zig
    /// _ = try handler.synchronizeAttachments();
    /// ```
    pub fn synchronizeAttachments(handler: *DeliverActivePaneResourcesHandler) !bool {
        if (handler.model.takeAgentAcknowledgement()) |key| {
            try handler.effects.acknowledge_agent(handler.effects.context, key);
        }

        const area = handler.effects.sync_attachment_target(
            handler.effects.context,
            handler.model.focusedAttachmentTarget(),
        ) orelse return false;

        try handler.effects.offer_pane_geometry(handler.effects.context, area);
        return true;
    }

    /// Synchronizes attachment geometry before child focus reporting.
    ///
    /// ```zig
    /// try handler.synchronize();
    /// ```
    pub fn synchronize(handler: *DeliverActivePaneResourcesHandler) !void {
        _ = try handler.synchronizeAttachments();
        try handler.effects.sync_focus_reporting(handler.effects.context);
    }

    /// Validates one committed focus and delivers its active-pane resources.
    /// Fullscreen geometry follows attachment and focus-report synchronization.
    ///
    /// ```zig
    /// try handler.deliverFocus(focus, area);
    /// ```
    pub fn deliverFocus(handler: *DeliverActivePaneResourcesHandler, focus: client_model.PaneFocus, area: ui.Rect) !void {
        try handler.validateFocus(focus);
        try handler.synchronize();
        if (!focus.geometry_changed) {
            return;
        }

        handler.effects.invalidate_graphics_placements(handler.effects.context);
        try handler.effects.offer_pane_geometry(handler.effects.context, area);
    }

    fn validateFocus(handler: *const DeliverActivePaneResourcesHandler, focus: client_model.PaneFocus) !void {
        const active = handler.model.workspace.activeConst() orelse return error.StalePaneFocus;
        if (!std.meta.eql(active.location, focus.location) or
            active.model.layout.focused() != focus.focused or
            handler.model.version().panes != focus.panes_revision)
        {
            return error.StalePaneFocus;
        }
    }
};

const Event = enum {
    acknowledge_agent,
    attachment_target,
    focus_reporting,
    invalidate_placements,
    pane_geometry,
};

const Failure = enum {
    none,
    focus_reporting,
    first_geometry,
    second_geometry,
};

const EffectCapture = struct {
    model: *const client_model.Model,
    expected_focus: ?client_model.PaneFocus = null,
    attachment_area: ?ui.Rect = null,
    attachment_target: ?attachments.Target = null,
    events: [6]Event = undefined,
    event_count: usize = 0,
    geometry_areas: [2]ui.Rect = undefined,
    geometry_count: usize = 0,
    committed_focus_observed: bool = true,
    failure: Failure = .none,
    acknowledged: ?agents.AgentKey = null,

    fn effects(capture: *EffectCapture) Effects {
        return .{
            .context = capture,
            .sync_attachment_target = syncAttachmentTarget,
            .sync_focus_reporting = syncFocusReporting,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
            .acknowledge_agent = acknowledgeAgent,
        };
    }

    fn acknowledgeAgent(raw_context: *anyopaque, key: agents.AgentKey) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.acknowledge_agent);
        capture.acknowledged = key;
    }

    fn syncAttachmentTarget(raw_context: *anyopaque, target: ?attachments.Target) ?ui.Rect {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.attachment_target);
        capture.attachment_target = target;

        return capture.attachment_area;
    }

    fn syncFocusReporting(raw_context: *anyopaque) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.focus_reporting);

        if (capture.failure == .focus_reporting) {
            return error.FocusReportingFailed;
        }
    }

    fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.invalidate_placements);
    }

    fn offerPaneGeometry(raw_context: *anyopaque, area: ui.Rect) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.pane_geometry);
        capture.geometry_areas[capture.geometry_count] = area;
        capture.geometry_count += 1;

        if (capture.failure == .first_geometry and capture.geometry_count == 1) {
            return error.PaneGeometryFailed;
        }
        if (capture.failure == .second_geometry and capture.geometry_count == 2) {
            return error.PaneGeometryFailed;
        }
    }

    fn append(capture: *EffectCapture, event: Event) void {
        capture.observeFocus();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeFocus(capture: *EffectCapture) void {
        const focus = capture.expected_focus orelse return;
        const active = capture.model.workspace.activeConst() orelse {
            capture.committed_focus_observed = false;
            return;
        };

        capture.committed_focus_observed = capture.committed_focus_observed and
            std.meta.eql(active.location, focus.location) and
            active.model.layout.focused() == focus.focused and
            capture.model.version().panes == focus.panes_revision;
    }

    fn eventSlice(capture: *const EffectCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn prepareModel(model: *client_model.Model, fullscreen: bool) !client_model.PaneFocus {
    const location: core.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: core.schema.PaneId = @enumFromInt(1);
    const second: core.schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    if (fullscreen) {
        try std.testing.expect(model.workspace.active().?.model.toggleFullscreen());
    }

    return model.focusPane(.{
        .target = .{ .pane_id = first },
        .area = area,
    }).?;
}

test "DeliverActivePaneResourcesHandler orders attachment focus and fullscreen geometry" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, true);
    const shelf_area: ui.Rect = .{ .x = 1, .y = 2, .w = 70, .h = 20 };
    const focus_area: ui.Rect = .{ .x = 3, .y = 4, .w = 60, .h = 18 };
    var capture: EffectCapture = .{
        .model = &model,
        .expected_focus = focus,
        .attachment_area = shelf_area,
    };
    var handler: DeliverActivePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.deliverFocus(focus, focus_area);

    try std.testing.expectEqualSlices(Event, &.{
        .attachment_target,
        .pane_geometry,
        .focus_reporting,
        .invalidate_placements,
        .pane_geometry,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(shelf_area, capture.geometry_areas[0]);
    try std.testing.expectEqualDeep(focus_area, capture.geometry_areas[1]);
    try std.testing.expect(capture.committed_focus_observed);
}

test "DeliverActivePaneResourcesHandler omits unchanged attachment and tiled geometry" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, false);
    var capture: EffectCapture = .{
        .model = &model,
        .expected_focus = focus,
    };
    var handler: DeliverActivePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.deliverFocus(focus, .{ .w = 80, .h = 24 });

    try std.testing.expectEqualSlices(Event, &.{
        .attachment_target,
        .focus_reporting,
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(usize, 0), capture.geometry_count);
    try std.testing.expect(capture.committed_focus_observed);
}

test "DeliverActivePaneResourcesHandler can synchronize attachments without focus reporting" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const area: ui.Rect = .{ .w = 70, .h = 20 };
    var capture: EffectCapture = .{
        .model = &model,
        .attachment_area = area,
    };
    var handler: DeliverActivePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.synchronizeAttachments());

    try std.testing.expectEqualSlices(Event, &.{
        .attachment_target,
        .pane_geometry,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(area, capture.geometry_areas[0]);

    capture.attachment_area = null;
    capture.event_count = 0;
    capture.geometry_count = 0;
    try std.testing.expect(!try handler.synchronizeAttachments());
    try std.testing.expectEqualSlices(Event, &.{.attachment_target}, capture.eventSlice());
}

test "DeliverActivePaneResourcesHandler rejects stale focus before effects" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const stale = try prepareModel(&model, false);
    _ = model.focusPane(.{
        .target = .{ .pane_id = stale.previous },
        .area = .{ .w = 80, .h = 24 },
    }).?;
    _ = model.focusPane(.{
        .target = .{ .pane_id = stale.focused },
        .area = .{ .w = 80, .h = 24 },
    }).?;
    try std.testing.expectEqual(stale.focused, model.workspace.activeConst().?.model.layout.focused().?);
    var capture: EffectCapture = .{ .model = &model };
    var handler: DeliverActivePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(
        error.StalePaneFocus,
        handler.deliverFocus(stale, .{ .w = 80, .h = 24 }),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverActivePaneResourcesHandler stops after each failed resource" {
    const failures = [_]Failure{
        .first_geometry,
        .focus_reporting,
        .second_geometry,
    };
    const expected = [_][]const Event{
        &.{ .attachment_target, .pane_geometry },
        &.{ .attachment_target, .pane_geometry, .focus_reporting },
        &.{ .attachment_target, .pane_geometry, .focus_reporting, .invalidate_placements, .pane_geometry },
    };

    for (failures, expected) |failure, events| {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        const focus = try prepareModel(&model, true);
        var capture: EffectCapture = .{
            .model = &model,
            .expected_focus = focus,
            .attachment_area = .{ .w = 70, .h = 20 },
            .failure = failure,
        };
        var handler: DeliverActivePaneResourcesHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        const result = handler.deliverFocus(focus, .{ .w = 80, .h = 24 });
        switch (failure) {
            .first_geometry, .second_geometry => try std.testing.expectError(error.PaneGeometryFailed, result),
            .focus_reporting => try std.testing.expectError(error.FocusReportingFailed, result),
            .none => unreachable,
        }
        try std.testing.expectEqualSlices(Event, events, capture.eventSlice());
        try std.testing.expect(capture.committed_focus_observed);
    }
}

test "DeliverActivePaneResourcesHandler acknowledges a focused done agent before the shelf" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, false);
    const key: agents.AgentKey = .{ .pane_id = focus.focused, .pane_generation = 3 };
    const entry: agents.AgentInput = .{
        .key = key,
        .location = focus.location,
        .pane_index = 1,
        .provider = .claude,
        .status = .done,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{entry} });
    var capture: EffectCapture = .{ .model = &model };
    var handler: DeliverActivePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.synchronizeAttachments());

    try std.testing.expectEqualSlices(Event, &.{
        .acknowledge_agent,
        .attachment_target,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(key, capture.acknowledged.?);

    try std.testing.expect(!try handler.synchronizeAttachments());

    try std.testing.expectEqual(@as(usize, 3), capture.event_count);
    try std.testing.expectEqual(Event.attachment_target, capture.eventSlice()[2]);
}
