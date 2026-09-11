//! Application policy for delivering disposable client resources after one
//! committed pane exit.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const pane_resource_release = @import("pane_resource_release.zig");

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;

pub const Effects = @import("PaneClosureDeliveryEffects.zig");

pub const DeliverPaneClosureHandler = @import("DeliverPaneClosureHandler.zig");

pub const Event = union(enum) {
    ignore_attachment: schema.PaneId,
    complete_close: schema.PaneId,
    clear_graphics: schema.PaneId,
    invalidate_placements,
    synchronize_active_resources,
    active_geometry_area,
    resize: schema.PaneId,
};

pub const Failure = enum {
    none,
    active_resources,
    resize,
};

const TestingModel = @import("PaneClosureDeliveryTestingModel.zig");

const EffectsCapture = @import("PaneClosureDeliveryEffectsCapture.zig");

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

    try stale_testing.model.workspace.active().?.model.split(.{ .existing_pane = stale_testing.second, .new_pane = missing, .location = stale_testing.active, .axis = .horizontal, .area = stale_testing.area });

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
