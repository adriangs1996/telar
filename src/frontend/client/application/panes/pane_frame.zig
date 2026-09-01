//! Application use case for reconciling one runtime pane frame.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");

const schema = core.schema;
const ui = core.ui;

pub const PaneFrameEffects = struct {
    context: *anyopaque,
    recover: *const fn (*anyopaque, client_model.PaneFrameRecovery) anyerror!void,
    deliver: *const fn (*anyopaque, client_model.PaneFrameCommit) anyerror!void,
};

pub const ApplyPaneFrameHandler = struct {
    model: *client_model.Model,
    effects: PaneFrameEffects,

    /// Commits a valid attached frame before updating client resources. A
    /// broken patch base requests a snapshot without mutation, while a frame
    /// made stale by detach has no effects.
    ///
    /// ```zig
    /// const outcome = try handler.execute(frame);
    /// ```
    pub fn execute(handler: *ApplyPaneFrameHandler, frame: schema.frame.FrameView) !client_model.PaneFrameOutcome {
        const outcome = try handler.model.applyPaneFrame(frame);
        switch (outcome) {
            .detached => {},
            .resync => |recovery| try handler.effects.recover(handler.effects.context, recovery),
            .applied => |commit| try handler.effects.deliver(handler.effects.context, commit),
        }

        return outcome;
    }
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

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const TestingFrame = struct {
    pane_id: schema.PaneId,
    frame_id: u64 = 1,
    base_frame_id: u64 = 0,
    cells: ?[]const ui.Cell = null,
};

fn testingFrame(buffer: []u8, input: TestingFrame) !schema.frame.FrameView {
    var spans: [1]schema.frame.Span = undefined;
    const encoded_spans: []const schema.frame.Span = if (input.cells) |cells| block: {
        spans[0] = .{ .start = 0, .cells = cells };
        break :block &spans;
    } else &.{};
    const encoded = try schema.encodePaneFrame(buffer, .{
        .pane_id = input.pane_id,
        .frame_id = input.frame_id,
        .base_frame_id = input.base_frame_id,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = encoded_spans,
    });

    return (try schema.decodeServer(encoded)).pane_frame;
}

const EffectEvent = enum {
    recover,
    deliver,
};

const EffectsCapture = struct {
    model: *client_model.Model,
    events: [1]EffectEvent = undefined,
    event_count: usize = 0,
    recovery: ?client_model.PaneFrameRecovery = null,
    commit: ?client_model.PaneFrameCommit = null,
    observed_commit: bool = false,
    fail_recovery: bool = false,
    fail_delivery: bool = false,

    fn port(capture: *EffectsCapture) PaneFrameEffects {
        return .{
            .context = capture,
            .recover = recover,
            .deliver = deliver,
        };
    }

    fn record(capture: *EffectsCapture, event: EffectEvent) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn recover(context: *anyopaque, recovery: client_model.PaneFrameRecovery) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.recover);
        capture.recovery = recovery;

        if (capture.fail_recovery) {
            return error.RecoveryFailed;
        }
    }

    fn deliver(context: *anyopaque, commit: client_model.PaneFrameCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const pane = capture.model.workspace.findPane(commit.pane_id).?;
        capture.record(.deliver);
        capture.commit = commit;
        capture.observed_commit = pane.applied_frame_id == commit.frame_id and
            capture.model.version().frame == commit.frame_revision;

        if (capture.fail_delivery) {
            return error.ResourceSyncFailed;
        }
    }
};

test "ApplyPaneFrameHandler commits before delivering client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const cells = [_]ui.Cell{ .{}, .{}, .{}, .{} };
    var encoded: [512]u8 = undefined;

    const outcome = try handler.execute(try testingFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 7,
        .cells = &cells,
    }));

    try std.testing.expect(outcome == .applied);
    try std.testing.expectEqualSlices(EffectEvent, &.{.deliver}, capture.events[0..capture.event_count]);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(outcome.applied, capture.commit.?);
}

test "ApplyPaneFrameHandler requests recovery without committing a broken base" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.applied_frame_id = 3;
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var encoded: [256]u8 = undefined;

    const outcome = try handler.execute(try testingFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 4,
        .base_frame_id = 2,
    }));

    try std.testing.expectEqualSlices(EffectEvent, &.{.recover}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(outcome.resync, capture.recovery.?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ApplyPaneFrameHandler suppresses frames made stale by detach" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: ApplyPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const cells = [_]ui.Cell{ .{}, .{}, .{}, .{} };
    var encoded: [512]u8 = undefined;

    const outcome = try handler.execute(try testingFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .cells = &cells,
    }));

    try std.testing.expect(outcome == .detached);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ApplyPaneFrameHandler preserves commits after resource delivery failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail_delivery = true };
    var handler: ApplyPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const cells = [_]ui.Cell{ .{}, .{}, .{}, .{} };
    var encoded: [512]u8 = undefined;

    try std.testing.expectError(error.ResourceSyncFailed, handler.execute(try testingFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 7,
        .cells = &cells,
    })));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(client_model.Version{ .frame = 1 }, testing.model.version());
    try std.testing.expectEqual(@as(u64, 7), testing.model.workspace.findPane(testing.pane_id).?.applied_frame_id);
}

test "ApplyPaneFrameHandler propagates recovery failure without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.applied_frame_id = 3;
    var capture: EffectsCapture = .{ .model = testing.model, .fail_recovery = true };
    var handler: ApplyPaneFrameHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    var encoded: [256]u8 = undefined;

    try std.testing.expectError(error.RecoveryFailed, handler.execute(try testingFrame(&encoded, .{
        .pane_id = testing.pane_id,
        .frame_id = 4,
        .base_frame_id = 2,
    })));

    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
    try std.testing.expectEqual(@as(u64, 3), testing.model.workspace.findPane(testing.pane_id).?.applied_frame_id);
}
