//! Application policy for delivering one committed sidebar layout.

const std = @import("std");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;

pub const multiplexer = workspace_capability.multiplexer;

pub const Effects = @import("SidebarLayoutDeliveryEffects.zig");

pub const DeliverSidebarLayoutHandler = @import("DeliverSidebarLayoutHandler.zig");

pub const Event = enum {
    project_view,
    invalidate_graphics,
    pane_geometry,
};

const TestingModel = @import("TestingModel.zig");

const EffectsCapture = @import("SidebarLayoutDeliveryEffectsCapture.zig");

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
