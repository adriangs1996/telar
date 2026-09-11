//! Application policy for the model-owned sidebar animation loop.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../root.zig").agents;
const client_model = @import("../../root.zig").model;

const schema = core.schema;

pub const Activity = enum {
    active,
    inactive,
};

pub const Effects = @import("SidebarAnimationEffects.zig");

pub const SidebarAnimationHandler = @import("SidebarAnimationHandler.zig");

const Capture = @import("Capture.zig");

fn reconcileAgent(model: *client_model.Model, revision: u64, status: schema.AgentStatus) !void {
    const agent: agents.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = status,
    };

    _ = try model.reconcileAgentSnapshot(.{ .revision = revision, .agents = &.{agent} });
}

test "SidebarAnimationHandler ignores synchronization and ticks while inactive" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(try handler.synchronize() == .inactive);
    try std.testing.expect((try handler.tick()) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(client_model.Version{}, model.version());
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());
}

test "SidebarAnimationHandler synchronizes without mutation and commits before rearming" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try reconcileAgent(&model, 1, .working);
    var capture: Capture = .{ .model = &model };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(try handler.synchronize() == .active);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.expected_revision = 1;
    capture.expected_frame = 1;
    const change = (try handler.tick()).?;

    try std.testing.expectEqual(@as(u8, 1), change.frame);
    try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(client_model.Version{
        .agents = 1,
        .sidebar_animation = 1,
    }, model.version());
}

test "SidebarAnimationHandler preserves a committed frame after scheduler failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try reconcileAgent(&model, 1, .working);
    var capture: Capture = .{
        .model = &model,
        .fail = true,
    };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expectError(error.AnimationScheduleFailed, handler.synchronize());

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());

    capture.expected_revision = 1;
    capture.expected_frame = 1;
    try std.testing.expectError(error.AnimationScheduleFailed, handler.tick());

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(u8, 1), model.sidebarAnimationFrame());
    try std.testing.expectEqual(client_model.Version{
        .agents = 1,
        .sidebar_animation = 1,
    }, model.version());
}
