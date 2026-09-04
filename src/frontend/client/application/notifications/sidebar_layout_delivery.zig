//! Application policy for delivering one committed sidebar layout.

const std = @import("std");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");

const multiplexer = workspace_capability.multiplexer;

pub const Effects = struct {
    context: *anyopaque,
    project_view: *const fn (*anyopaque, bool, u16) void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    offer_pane_geometry: *const fn (*anyopaque, *multiplexer.Model) anyerror!void,
};

pub const DeliverSidebarLayoutHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Validates one exact sidebar commit before projecting the view,
    /// invalidating graphics and re-offering active pane geometry.
    ///
    /// ```zig
    /// try handler.execute(change);
    /// ```
    pub fn execute(handler: *const DeliverSidebarLayoutHandler, change: client_model.SidebarLayout) !void {
        if (handler.model.sidebarVisible() != change.visible or handler.model.sidebarWidth() != change.width or
            handler.model.version().chrome != change.chrome_revision)
        {
            return error.StaleSidebarLayout;
        }

        handler.effects.project_view(handler.effects.context, change.visible, change.width);
        handler.effects.invalidate_graphics_placements(handler.effects.context);
        const active = handler.model.workspace.active() orelse return;

        try handler.effects.offer_pane_geometry(handler.effects.context, &active.model);
    }
};

const Event = enum {
    project_view,
    invalidate_graphics,
    pane_geometry,
};

const TestingModel = struct {
    model: *client_model.Model,

    fn init(active: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        if (active) {
            try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(1),
            }, .size = .{ .cols = 20, .rows = 5 } });
        }

        return .{ .model = model };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected: client_model.SidebarLayout,
    events: [3]Event = undefined,
    event_count: usize = 0,
    projected_visible: ?bool = null,
    projected_width: ?u16 = null,
    offered_model: ?*multiplexer.Model = null,
    observed_commit: bool = true,
    fail_geometry: bool = false,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .project_view = projectView,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
        };
    }

    fn projectView(context: *anyopaque, visible: bool, width: u16) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.project_view);
        capture.projected_visible = visible;
        capture.projected_width = width;
    }

    fn invalidateGraphicsPlacements(context: *anyopaque) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.invalidate_graphics);
    }

    fn offerPaneGeometry(context: *anyopaque, model: *multiplexer.Model) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.pane_geometry);
        capture.offered_model = model;

        if (capture.fail_geometry) {
            return error.PaneGeometryDeliveryFailed;
        }
    }

    fn record(capture: *EffectsCapture, event: Event) void {
        capture.observed_commit = capture.observed_commit and
            capture.model.sidebarVisible() == capture.expected.visible and
            capture.model.sidebarWidth() == capture.expected.width and
            capture.model.version().chrome == capture.expected.chrome_revision;
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }
};

fn expectStale(handler: *const DeliverSidebarLayoutHandler, capture: *const EffectsCapture, change: client_model.SidebarLayout) !void {
    try std.testing.expectError(error.StaleSidebarLayout, handler.execute(change));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverSidebarLayoutHandler orders the complete active projection" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarLayoutHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(change);

    try std.testing.expectEqualSlices(
        Event,
        &.{ .project_view, .invalidate_graphics, .pane_geometry },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqual(change.visible, capture.projected_visible.?);
    try std.testing.expectEqual(change.width, capture.projected_width.?);
    try std.testing.expect(capture.offered_model == &testing.model.workspace.active().?.model);
    try std.testing.expect(capture.observed_commit);
}

test "DeliverSidebarLayoutHandler projects an empty workspace without geometry" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarLayoutHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(change);

    try std.testing.expectEqualSlices(
        Event,
        &.{ .project_view, .invalidate_graphics },
        capture.events[0..capture.event_count],
    );
    try std.testing.expect(capture.offered_model == null);
    try std.testing.expect(capture.observed_commit);
}

test "DeliverSidebarLayoutHandler rejects stale commits before effects" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarLayoutHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try expectStale(&handler, &capture, .{
        .visible = !change.visible,
        .chrome_revision = change.chrome_revision,
    });
    try expectStale(&handler, &capture, .{
        .visible = change.visible,
        .chrome_revision = change.chrome_revision - 1,
    });
}

test "DeliverSidebarLayoutHandler retains completed projection after geometry failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
        .fail_geometry = true,
    };
    const handler: DeliverSidebarLayoutHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.PaneGeometryDeliveryFailed, handler.execute(change));

    try std.testing.expectEqualSlices(
        Event,
        &.{ .project_view, .invalidate_graphics, .pane_geometry },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqual(change.visible, testing.model.sidebarVisible());
    try std.testing.expectEqual(change.chrome_revision, testing.model.version().chrome);
    try std.testing.expect(capture.observed_commit);
}
