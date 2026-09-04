//! Application policy for selecting and delivering client-owned pane geometry.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");

const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const ui = core.ui;

pub const OfferEffects = struct {
    context: *anyopaque,
    deliver_resize: *const fn (*anyopaque, schema.PaneResize) anyerror!void,
    bottom_reservation: *const fn (*anyopaque) ?layout_mod.PaneBottomReservation = noBottomReservation,
};

pub const Effects = struct {
    context: *anyopaque,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    deliver_resize: *const fn (*anyopaque, schema.PaneResize) anyerror!void,
    bottom_reservation: *const fn (*anyopaque) ?layout_mod.PaneBottomReservation = noBottomReservation,
};

pub const OfferPaneGeometryHandler = struct {
    effects: OfferEffects,

    /// Offers every attached pane that has visible content in the supplied
    /// layout rectangle.
    ///
    /// ```zig
    /// const count = try handler.execute(model, area);
    /// ```
    pub fn execute(handler: *OfferPaneGeometryHandler, model: *multiplexer.Model, area: ui.Rect) !usize {
        var count: usize = 0;
        var layout = model.layoutSnapshot(area).*;
        _ = layout.reserveBelowPane(handler.effects.bottom_reservation(handler.effects.context));
        var panes = model.paneIterator();
        while (panes.next()) |pane| {
            if (!pane.attached) {
                continue;
            }

            const view = layout.find(pane.id) orelse continue;
            var size = multiplexer.rectSize(view.content) orelse continue;
            size.cell_width_px = model.cell_width_px;
            size.cell_height_px = model.cell_height_px;
            try handler.effects.deliver_resize(handler.effects.context, .{
                .pane_id = pane.id,
                .size = size,
            });
            count += 1;
        }

        return count;
    }
};

pub const OfferActivePaneGeometryHandler = struct {
    model: *client_model.Model,
    effects: OfferEffects,

    /// Selects the active tab once and offers its attached visible panes.
    /// An empty client has no geometry to deliver.
    ///
    /// ```zig
    /// const count = try handler.execute(area);
    /// ```
    pub fn execute(handler: *OfferActivePaneGeometryHandler, area: ui.Rect) !usize {
        const active = handler.model.workspace.active() orelse return 0;
        var offer: OfferPaneGeometryHandler = .{ .effects = handler.effects };

        return offer.execute(&active.model, area);
    }
};

pub const DeliverPaneGeometryHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Validates one committed geometry change before invalidating placements
    /// and offering its visible attached pane sizes.
    ///
    /// ```zig
    /// const count = try handler.execute(change);
    /// ```
    pub fn execute(handler: *DeliverPaneGeometryHandler, change: client_model.PaneGeometryChange) !usize {
        const active = handler.model.workspace.active() orelse return error.StalePaneGeometry;
        if (!std.meta.eql(active.location, change.location) or
            active.model.layout.focused() != change.focused or
            active.model.layout.isFullscreen() != change.fullscreen or
            handler.model.version().panes != change.panes_revision)
        {
            return error.StalePaneGeometry;
        }

        handler.effects.invalidate_graphics_placements(handler.effects.context);
        var offer: OfferPaneGeometryHandler = .{ .effects = .{
            .context = handler.effects.context,
            .deliver_resize = handler.effects.deliver_resize,
            .bottom_reservation = handler.effects.bottom_reservation,
        } };

        return offer.execute(&active.model, change.area);
    }
};

fn noBottomReservation(context: *anyopaque) ?layout_mod.PaneBottomReservation {
    _ = context;

    return null;
}

const Event = enum {
    invalidate_placements,
    resize,
};

const EffectCapture = struct {
    model: ?*const client_model.Model = null,
    expected_revision: u64 = 0,
    events: [5]Event = undefined,
    event_count: usize = 0,
    resizes: [multiplexer.max_panes]schema.PaneResize = undefined,
    resize_count: usize = 0,
    committed_geometry_observed: bool = true,
    fail_resize: ?usize = null,
    bottom_reservation: ?layout_mod.PaneBottomReservation = null,

    fn offerEffects(capture: *EffectCapture) OfferEffects {
        return .{
            .context = capture,
            .deliver_resize = deliverResize,
            .bottom_reservation = bottomReservation,
        };
    }

    fn effects(capture: *EffectCapture) Effects {
        return .{
            .context = capture,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .deliver_resize = deliverResize,
            .bottom_reservation = bottomReservation,
        };
    }

    fn bottomReservation(raw_context: *anyopaque) ?layout_mod.PaneBottomReservation {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));

        return capture.bottom_reservation;
    }

    fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.invalidate_placements);
    }

    fn deliverResize(raw_context: *anyopaque, resize: schema.PaneResize) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.resize);
        capture.resizes[capture.resize_count] = resize;
        capture.resize_count += 1;

        if (capture.fail_resize == capture.resize_count) {
            return error.PaneResizeDeliveryFailed;
        }
    }

    fn append(capture: *EffectCapture, event: Event) void {
        if (capture.model) |model| {
            capture.committed_geometry_observed = capture.committed_geometry_observed and
                model.version().panes == capture.expected_revision;
        }

        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn reset(capture: *EffectCapture) void {
        capture.event_count = 0;
        capture.resize_count = 0;
    }

    fn eventSlice(capture: *const EffectCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

const TestingLayout = struct {
    location: schema.TabLocation,
    first: schema.PaneId,
    second: schema.PaneId,
    area: ui.Rect,
};

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
    try model.workspace.bootstrap(testing.first, testing.location, .{ .cols = 100, .rows = 30 });
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
