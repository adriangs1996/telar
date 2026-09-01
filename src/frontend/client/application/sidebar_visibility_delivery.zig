//! Application policy for delivering one committed sidebar visibility.

const std = @import("std");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../model.zig");

const multiplexer = workspace_capability.multiplexer;

pub const Effects = struct {
    context: *anyopaque,
    project_view: *const fn (*anyopaque, bool) void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    offer_pane_geometry: *const fn (*anyopaque, *multiplexer.Model) anyerror!void,
};

pub const DeliverSidebarVisibilityHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Validates one exact sidebar commit before projecting the view,
    /// invalidating graphics and re-offering active pane geometry.
    ///
    /// ```zig
    /// try handler.execute(change);
    /// ```
    pub fn execute(handler: *const DeliverSidebarVisibilityHandler, change: client_model.SidebarVisibility) !void {
        if (handler.model.sidebarVisible() != change.visible or
            handler.model.version().chrome != change.chrome_revision)
        {
            return error.StaleSidebarVisibility;
        }

        handler.effects.project_view(handler.effects.context, change.visible);
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
            try model.workspace.bootstrap(@enumFromInt(1), .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(1),
            }, .{ .cols = 20, .rows = 5 });
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
    expected: client_model.SidebarVisibility,
    events: [3]Event = undefined,
    event_count: usize = 0,
    projected_visible: ?bool = null,
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

    fn projectView(context: *anyopaque, visible: bool) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.project_view);
        capture.projected_visible = visible;
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
            capture.model.version().chrome == capture.expected.chrome_revision;
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }
};

fn expectStale(handler: *const DeliverSidebarVisibilityHandler, capture: *const EffectsCapture, change: client_model.SidebarVisibility) !void {
    try std.testing.expectError(error.StaleSidebarVisibility, handler.execute(change));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverSidebarVisibilityHandler orders the complete active projection" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarVisibilityHandler = .{
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
    try std.testing.expect(capture.offered_model == &testing.model.workspace.active().?.model);
    try std.testing.expect(capture.observed_commit);
}

test "DeliverSidebarVisibilityHandler projects an empty workspace without geometry" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarVisibilityHandler = .{
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

test "DeliverSidebarVisibilityHandler rejects stale commits before effects" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
    };
    const handler: DeliverSidebarVisibilityHandler = .{
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

test "DeliverSidebarVisibilityHandler retains completed projection after geometry failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const change = testing.model.toggleSidebar();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .expected = change,
        .fail_geometry = true,
    };
    const handler: DeliverSidebarVisibilityHandler = .{
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
