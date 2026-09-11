//! Application use case for reconciling one runtime pane frame.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;
pub const ui = core.ui;

pub const PaneFrameEffects = @import("PaneFrameEffects.zig");

pub const ApplyPaneFrameHandler = @import("ApplyPaneFrameHandler.zig");

const TestingModel = @import("PaneFrameTestingModel.zig");

const TestingFrame = @import("TestingFrame.zig");

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

pub const EffectEvent = enum {
    recover,
    deliver,
};

const EffectsCapture = @import("PaneFrameEffectsCapture.zig");

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
