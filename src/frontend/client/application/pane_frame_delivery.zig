//! Application policy for delivering client resources after one committed
//! runtime pane frame.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;
const ui = core.ui;

pub const Effects = struct {
    context: *anyopaque,
    pane_graphics_visible: *const fn (*anyopaque, schema.PaneId) bool,
    set_pane_graphics_visible: *const fn (*anyopaque, schema.PaneId, bool) anyerror!void,
    synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
};

pub const DeliverPaneFrameHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Validates one exact frame commit before reconciling graphics visibility
    /// and the resources derived from the currently active pane.
    ///
    /// ```zig
    /// try handler.execute(commit);
    /// ```
    pub fn execute(handler: *DeliverPaneFrameHandler, commit: client_model.PaneFrameCommit) !void {
        try handler.validate(commit);

        const visible = handler.effects.pane_graphics_visible(handler.effects.context, commit.pane_id);
        if (visible != commit.graphics_visible) {
            try handler.effects.set_pane_graphics_visible(
                handler.effects.context,
                commit.pane_id,
                commit.graphics_visible,
            );
        }

        if (handler.model.workspace.activeConst() != null) {
            try handler.effects.synchronize_active_resources(handler.effects.context);
        }
    }

    fn validate(handler: *const DeliverPaneFrameHandler, commit: client_model.PaneFrameCommit) !void {
        const tab = handler.model.workspace.tabForPaneConst(commit.pane_id) orelse return error.StalePaneFrame;
        if (!std.meta.eql(tab.location, commit.location)) {
            return error.StalePaneFrame;
        }

        const pane = tab.model.findConst(commit.pane_id) orelse return error.StalePaneFrame;
        const active = handler.model.workspace.activeConst();
        const graphics_visible = pane.scroll.atBottom(pane.buffer.h) and
            active != null and std.meta.eql(active.?.location, tab.location);
        const version = handler.model.version();
        if (!pane.attached or
            pane.applied_frame_id != commit.frame_id or
            graphics_visible != commit.graphics_visible or
            version.workspace != commit.workspace_revision or
            version.tabs != commit.tabs_revision or
            version.active_tab != commit.active_tab_revision or
            version.panes != commit.panes_revision or
            version.frame != commit.frame_revision)
        {
            return error.StalePaneFrame;
        }
    }
};

const Event = enum {
    read_graphics_visibility,
    set_graphics_visibility,
    synchronize_active_resources,
};

const Failure = enum {
    none,
    graphics_visibility,
    active_resources,
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });

        return .{
            .model = model,
            .pane_id = pane_id,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn applyFrame(testing: *TestingModel, scroll: schema.frame.Scroll) !client_model.PaneFrameCommit {
        const cells = [_]ui.Cell{ .{}, .{}, .{}, .{} };
        var encoded: [512]u8 = undefined;
        const bytes = try schema.encodePaneFrame(&encoded, .{
            .pane_id = testing.pane_id,
            .frame_id = 7,
            .base_frame_id = 0,
            .cols = 2,
            .rows = 2,
            .scroll = scroll,
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        const outcome = try testing.model.applyPaneFrame((try schema.decodeServer(bytes)).pane_frame);

        return outcome.applied;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    commit: client_model.PaneFrameCommit,
    current_visibility: bool,
    events: [3]Event = undefined,
    event_count: usize = 0,
    observed_pane: ?schema.PaneId = null,
    delivered_visibility: ?bool = null,
    committed_state_observed: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .pane_graphics_visible = paneGraphicsVisible,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
        };
    }

    fn paneGraphicsVisible(raw_context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.read_graphics_visibility);
        capture.observed_pane = pane_id;

        return capture.current_visibility;
    }

    fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.set_graphics_visibility);
        capture.observed_pane = pane_id;
        capture.delivered_visibility = visible;
        if (capture.failure == .graphics_visibility) {
            return error.GraphicsVisibilityFailed;
        }

        capture.current_visibility = visible;
    }

    fn synchronizeActiveResources(raw_context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        capture.append(.synchronize_active_resources);
        if (capture.failure == .active_resources) {
            return error.ActiveResourceSyncFailed;
        }
    }

    fn append(capture: *EffectsCapture, event: Event) void {
        capture.observeCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeCommit(capture: *EffectsCapture) void {
        const tab = capture.model.workspace.tabForPaneConst(capture.commit.pane_id) orelse {
            capture.committed_state_observed = false;
            return;
        };
        const pane = tab.model.findConst(capture.commit.pane_id) orelse {
            capture.committed_state_observed = false;
            return;
        };
        const version = capture.model.version();

        capture.committed_state_observed = capture.committed_state_observed and
            std.meta.eql(tab.location, capture.commit.location) and
            pane.applied_frame_id == capture.commit.frame_id and
            version.workspace == capture.commit.workspace_revision and
            version.tabs == capture.commit.tabs_revision and
            version.active_tab == capture.commit.active_tab_revision and
            version.panes == capture.commit.panes_revision and
            version.frame == capture.commit.frame_revision;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

test "DeliverPaneFrameHandler orders changed visibility before active resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = false,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .set_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expectEqual(testing.pane_id, capture.observed_pane.?);
    try std.testing.expectEqual(true, capture.delivered_visibility.?);
    try std.testing.expect(capture.current_visibility);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneFrameHandler preserves matching graphics visibility" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(?bool, null), capture.delivered_visibility);
}

test "DeliverPaneFrameHandler rejects stale topology and frame revisions" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    testing.model.workspace_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.workspace_revision -%= 1;

    testing.model.tabs_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.tabs_revision -%= 1;

    testing.model.active_tab_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.active_tab_revision -%= 1;

    testing.model.panes_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    testing.model.panes_revision -%= 1;

    testing.model.frame_revision +%= 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneFrameHandler rejects stale pane state" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };
    const pane = testing.model.workspace.findPane(testing.pane_id).?;

    pane.attached = false;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    pane.attached = true;

    pane.applied_frame_id += 1;
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));
    pane.applied_frame_id -= 1;

    pane.scroll = .{ .total_rows = 3, .offset = 0 };
    try std.testing.expectError(error.StalePaneFrame, handler.execute(commit));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPaneFrameHandler stops after graphics visibility failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = false,
        .failure = .graphics_visibility,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.GraphicsVisibilityFailed, handler.execute(commit));

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .set_graphics_visibility,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverPaneFrameHandler propagates active resource failure after visibility" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const commit = try testing.applyFrame(.{ .total_rows = 2, .offset = 0 });
    var capture: EffectsCapture = .{
        .model = testing.model,
        .commit = commit,
        .current_visibility = true,
        .failure = .active_resources,
    };
    var handler: DeliverPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.ActiveResourceSyncFailed, handler.execute(commit));

    try std.testing.expectEqualSlices(Event, &.{
        .read_graphics_visibility,
        .synchronize_active_resources,
    }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
}
