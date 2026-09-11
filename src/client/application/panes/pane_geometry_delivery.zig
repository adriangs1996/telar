//! Application policy for selecting and delivering client-owned pane geometry.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;

pub const layout_mod = workspace_capability.layout;
pub const multiplexer = workspace_capability.multiplexer;
pub const schema = core.schema;
pub const ui = core.ui;

pub const OfferEffects = @import("OfferEffects.zig");

pub const Effects = @import("PaneGeometryDeliveryEffects.zig");

pub const OfferPaneGeometryHandler = @import("OfferPaneGeometryHandler.zig");

pub const OfferActivePaneGeometryHandler = @import("OfferActivePaneGeometryHandler.zig");

pub const DeliverPaneGeometryHandler = @import("DeliverPaneGeometryHandler.zig");

pub fn noBottomReservation(context: *anyopaque) ?layout_mod.PaneBottomReservation {
    _ = context;

    return null;
}

pub const Event = enum {
    invalidate_placements,
    resize,
    request_attachments,
};

const EffectCapture = @import("PaneGeometryDeliveryEffectCapture.zig");

const TestingLayout = @import("TestingLayout.zig");

fn prepareModel(model: *client_model.Model) !TestingLayout {
    const testing: TestingLayout = .{
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .first = @enumFromInt(1),
        .second = @enumFromInt(2),
        .area = .{ .w = 100, .h = 30 },
    };
    try model.workspace.bootstrap(.{ .pane_id = testing.first, .location = testing.location, .size = .{ .cols = 100, .rows = 30 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = testing.first, .new_pane = testing.second, .location = testing.location, .axis = .horizontal, .area = testing.area });

    return testing;
}

test "OfferPaneGeometryHandler selects only attached visible panes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    const active = &model.workspace.active().?.model;
    var capture: EffectCapture = .{};
    var handler: OfferPaneGeometryHandler = .{ .effects = capture.offerEffects() };

    try std.testing.expectEqual(@as(usize, 2), try handler.execute(active, testing.area));
    try std.testing.expectEqual(@as(usize, 2), capture.resize_count);
    try std.testing.expectEqualDeep(
        active.contentSize(capture.resizes[0].pane_id, testing.area).?,
        capture.resizes[0].size,
    );
    try std.testing.expectEqualDeep(
        active.contentSize(capture.resizes[1].pane_id, testing.area).?,
        capture.resizes[1].size,
    );

    active.find(testing.first).?.attached = false;
    capture.reset();

    try std.testing.expectEqual(@as(usize, 1), try handler.execute(active, testing.area));
    try std.testing.expectEqual(testing.second, capture.resizes[0].pane_id);

    active.find(testing.first).?.attached = true;
    capture.reset();
    try std.testing.expect(active.toggleFullscreen());

    try std.testing.expectEqual(@as(usize, 1), try handler.execute(active, testing.area));
    try std.testing.expectEqual(testing.second, capture.resizes[0].pane_id);
}

test "OfferPaneGeometryHandler reserves rows only from the target pane" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    const active = &model.workspace.active().?.model;
    const first_size = active.contentSize(testing.first, testing.area).?;
    const second_size = active.contentSize(testing.second, testing.area).?;
    var capture: EffectCapture = .{};
    var handler: OfferPaneGeometryHandler = .{ .effects = capture.offerEffects() };
    capture.bottom_reservation = .{
        .pane_id = testing.second,
        .preferred_height = 6,
        .minimum_height = 3,
        .minimum_pane_height = 3,
    };

    try std.testing.expectEqual(@as(usize, 2), try handler.execute(active, testing.area));

    try std.testing.expectEqual(testing.first, capture.resizes[0].pane_id);
    try std.testing.expectEqual(first_size, capture.resizes[0].size);
    try std.testing.expectEqual(testing.second, capture.resizes[1].pane_id);
    try std.testing.expectEqual(second_size.cols, capture.resizes[1].size.cols);
    try std.testing.expectEqual(second_size.rows - 6, capture.resizes[1].size.rows);
}

test "OfferActivePaneGeometryHandler selects the active tab and propagates delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    var capture: EffectCapture = .{};
    var handler: OfferActivePaneGeometryHandler = .{
        .model = &model,
        .effects = capture.offerEffects(),
    };

    try std.testing.expectEqual(@as(usize, 2), try handler.execute(testing.area));
    try std.testing.expectEqual(testing.first, capture.resizes[0].pane_id);
    try std.testing.expectEqual(testing.second, capture.resizes[1].pane_id);

    capture.reset();
    capture.fail_resize = 1;

    try std.testing.expectError(error.PaneResizeDeliveryFailed, handler.execute(testing.area));
    try std.testing.expectEqual(@as(usize, 1), capture.resize_count);
}

test "OfferActivePaneGeometryHandler suppresses geometry for an empty client" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectCapture = .{};
    var handler: OfferActivePaneGeometryHandler = .{
        .model = &model,
        .effects = capture.offerEffects(),
    };

    try std.testing.expectEqual(@as(usize, 0), try handler.execute(.{ .w = 100, .h = 30 }));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneGeometryHandler validates then invalidates before resize delivery" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    try std.testing.expect(model.workspace.active().?.model.focusPane(testing.first));
    const width_before = model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    const change = model.resizePane(.{
        .direction = .right,
        .area = testing.area,
    }).?;
    var capture: EffectCapture = .{
        .model = &model,
        .expected_revision = change.panes_revision,
    };
    var handler: DeliverPaneGeometryHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectEqual(@as(usize, 2), try handler.execute(change));

    try std.testing.expectEqualSlices(Event, &.{
        .invalidate_placements,
        .resize,
        .resize,
        .request_attachments,
    }, capture.eventSlice());
    try std.testing.expect(
        model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols > width_before,
    );
    try std.testing.expect(capture.committed_geometry_observed);
}

test "DeliverPaneGeometryHandler rejects a superseded matching geometry" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    try std.testing.expect(model.workspace.active().?.model.focusPane(testing.first));
    const stale = model.resizePane(.{
        .direction = .right,
        .area = testing.area,
    }).?;
    _ = model.togglePaneFullscreen(.{ .area = testing.area }).?;
    _ = model.togglePaneFullscreen(.{ .area = testing.area }).?;
    try std.testing.expect(!model.workspace.activeConst().?.model.layout.isFullscreen());
    var capture: EffectCapture = .{};
    var handler: DeliverPaneGeometryHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.StalePaneGeometry, handler.execute(stale));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneGeometryHandler preserves the commit after partial delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const testing = try prepareModel(&model);
    try std.testing.expect(model.workspace.active().?.model.focusPane(testing.first));
    const change = model.resizePane(.{
        .direction = .right,
        .area = testing.area,
    }).?;
    var capture: EffectCapture = .{
        .model = &model,
        .expected_revision = change.panes_revision,
        .fail_resize = 2,
    };
    var handler: DeliverPaneGeometryHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.PaneResizeDeliveryFailed, handler.execute(change));

    try std.testing.expectEqualSlices(Event, &.{
        .invalidate_placements,
        .resize,
        .resize,
    }, capture.eventSlice());
    try std.testing.expectEqual(change.panes_revision, model.version().panes);
    try std.testing.expect(capture.committed_geometry_observed);
}
