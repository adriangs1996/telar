//! Application policy for delivering one committed pane viewport.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    set_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    deliver_viewport: *const fn (*anyopaque, schema.SetPaneViewport) anyerror!void,
};

pub const DeliverPaneViewportHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Validates one exact viewport commit before synchronizing graphics and
    /// then the runtime attachment.
    ///
    /// ```zig
    /// try handler.execute(change);
    /// ```
    pub fn execute(handler: *const DeliverPaneViewportHandler, change: client_model.PaneViewportChange) !void {
        const active = handler.model.workspace.activeConst() orelse return error.StalePaneViewport;
        const pane = active.model.findConst(change.pane_id) orelse return error.StalePaneViewport;
        if (!pane.attached or
            pane.scroll.offset != change.offset or
            pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
            handler.model.version().viewport != change.viewport_revision)
        {
            return error.StalePaneViewport;
        }

        try handler.effects.set_graphics_visible(
            handler.effects.context,
            change.pane_id,
            change.at_bottom,
        );
        try handler.effects.deliver_viewport(handler.effects.context, .{
            .pane_id = change.pane_id,
            .offset = change.offset,
        });
    }
};

const Event = enum {
    graphics,
    runtime,
};

const Failure = enum {
    none,
    graphics,
    runtime,
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .{ .cols = 10, .rows = 5 });
        model.workspace.findPane(pane_id).?.scroll = .{ .total_rows = 20, .offset = 10 };

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn commitBottom(testing: *TestingModel) client_model.PaneViewportChange {
        return testing.model.setPaneViewport(.{
            .pane_id = testing.pane_id,
            .target = .bottom,
        }).?;
    }
};

const EffectsCapture = struct {
    events: [2]Event = undefined,
    event_count: usize = 0,
    graphics_pane: ?schema.PaneId = null,
    visible: ?bool = null,
    viewport: ?schema.SetPaneViewport = null,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .set_graphics_visible = setGraphicsVisible,
            .deliver_viewport = deliverViewport,
        };
    }

    fn setGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.graphics);
        capture.graphics_pane = pane_id;
        capture.visible = visible;

        if (capture.failure == .graphics) {
            return error.GraphicsDeliveryFailed;
        }
    }

    fn deliverViewport(context: *anyopaque, viewport: schema.SetPaneViewport) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.append(.runtime);
        capture.viewport = viewport;

        if (capture.failure == .runtime) {
            return error.RuntimeDeliveryFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }
};

fn expectStale(handler: *const DeliverPaneViewportHandler, capture: *EffectsCapture, change: client_model.PaneViewportChange) !void {
    try std.testing.expectError(error.StalePaneViewport, handler.execute(change));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneViewportHandler orders graphics before runtime delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const change = testing.commitBottom();
    var capture: EffectsCapture = .{};
    const handler: DeliverPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(change);

    try std.testing.expectEqualSlices(Event, &.{ .graphics, .runtime }, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(change.pane_id, capture.graphics_pane.?);
    try std.testing.expect(capture.visible.?);
    try std.testing.expectEqualDeep(schema.SetPaneViewport{
        .pane_id = change.pane_id,
        .offset = change.offset,
    }, capture.viewport.?);
}

test "DeliverPaneViewportHandler rejects every stale commit before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const change = testing.commitBottom();
    var capture: EffectsCapture = .{};
    const handler: DeliverPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    var stale = change;
    stale.pane_id = @enumFromInt(9);
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.offset -= 1;
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.at_bottom = false;
    try expectStale(&handler, &capture, stale);

    stale = change;
    stale.viewport_revision +%= 1;
    try expectStale(&handler, &capture, stale);

    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    try expectStale(&handler, &capture, change);
    testing.model.workspace.findPane(testing.pane_id).?.attached = true;

    var empty = client_model.Model.init(std.testing.allocator, true);
    defer empty.deinit();
    const empty_handler: DeliverPaneViewportHandler = .{
        .model = &empty,
        .effects = capture.effects(),
    };
    try expectStale(&empty_handler, &capture, change);
}

test "DeliverPaneViewportHandler preserves completed effects after delivery failure" {
    inline for (.{ Failure.graphics, Failure.runtime }) |failure| {
        var testing = try TestingModel.init();
        defer testing.deinit();
        const change = testing.commitBottom();
        var capture: EffectsCapture = .{ .failure = failure };
        const handler: DeliverPaneViewportHandler = .{
            .model = testing.model,
            .effects = capture.effects(),
        };

        const expected_error = switch (failure) {
            .graphics => error.GraphicsDeliveryFailed,
            .runtime => error.RuntimeDeliveryFailed,
            .none => unreachable,
        };
        try std.testing.expectError(expected_error, handler.execute(change));

        const expected_events: []const Event = switch (failure) {
            .graphics => &.{.graphics},
            .runtime => &.{ .graphics, .runtime },
            .none => unreachable,
        };
        try std.testing.expectEqualSlices(Event, expected_events, capture.events[0..capture.event_count]);
        try std.testing.expectEqual(change.offset, testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
        try std.testing.expectEqual(change.viewport_revision, testing.model.version().viewport);
    }
}
