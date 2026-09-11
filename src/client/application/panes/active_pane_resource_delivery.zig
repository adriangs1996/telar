//! Application policy for synchronizing resources derived from the client's
//! active focused pane.

const ModelType = @import("../../model/Model.zig");
const PaneFocusType = @import("../../model/PaneFocus.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const std = @import("std");
const ActivePaneResourceDeliveryEffectCapture = @import("ActivePaneResourceDeliveryEffectCapture.zig");
const DeliverActivePaneResourcesHandler = @import("DeliverActivePaneResourcesHandler.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
const AgentInputType = @import("../../agents/AgentInput.zig");

pub const Event = enum {
    acknowledge_agent,
    attachment_target,
    focus_reporting,
    invalidate_placements,
    pane_geometry,
    request_attachments,
};

pub const Failure = enum {
    none,
    focus_reporting,
    first_geometry,
    second_geometry,
    attachments,
};

fn prepareModel(model: *ModelType, fullscreen: bool) !PaneFocusType {
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    const area: RectType = .{ .w = 80, .h = 24 };
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, true);
    const shelf_area: RectType = .{ .x = 1, .y = 2, .w = 70, .h = 20 };
    const focus_area: RectType = .{ .x = 3, .y = 4, .w = 60, .h = 18 };
    var capture: ActivePaneResourceDeliveryEffectCapture = .{
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
        .request_attachments,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(shelf_area, capture.geometry_areas[0]);
    try std.testing.expectEqualDeep(focus_area, capture.geometry_areas[1]);
    try std.testing.expect(capture.committed_focus_observed);
}

test "DeliverActivePaneResourcesHandler omits unchanged attachment and tiled geometry" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, false);
    var capture: ActivePaneResourceDeliveryEffectCapture = .{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const area: RectType = .{ .w = 70, .h = 20 };
    var capture: ActivePaneResourceDeliveryEffectCapture = .{
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
    var model = ModelType.init(std.testing.allocator, true);
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
    var capture: ActivePaneResourceDeliveryEffectCapture = .{ .model = &model };
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
        .attachments,
    };
    const expected = [_][]const Event{
        &.{ .attachment_target, .pane_geometry },
        &.{ .attachment_target, .pane_geometry, .focus_reporting },
        &.{ .attachment_target, .pane_geometry, .focus_reporting, .invalidate_placements, .pane_geometry },
        &.{ .attachment_target, .pane_geometry, .focus_reporting, .invalidate_placements, .pane_geometry, .request_attachments },
    };

    for (failures, expected) |failure, events| {
        var model = ModelType.init(std.testing.allocator, true);
        defer model.deinit();
        const focus = try prepareModel(&model, true);
        var capture: ActivePaneResourceDeliveryEffectCapture = .{
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
            .attachments => try std.testing.expectError(error.PaneAttachmentFailed, result),
            .none => unreachable,
        }
        try std.testing.expectEqualSlices(Event, events, capture.eventSlice());
        try std.testing.expect(capture.committed_focus_observed);
    }
}

test "DeliverActivePaneResourcesHandler acknowledges a focused done agent before the shelf" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const focus = try prepareModel(&model, false);
    const key: AgentKeyType = .{ .pane_id = focus.focused, .pane_generation = 3 };
    const entry: AgentInputType = .{
        .key = key,
        .location = focus.location,
        .pane_index = 1,
        .provider = .claude,
        .status = .done,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{entry} });
    var capture: ActivePaneResourceDeliveryEffectCapture = .{ .model = &model };
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
