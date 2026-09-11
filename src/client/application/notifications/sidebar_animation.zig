//! Application policy for the model-owned sidebar animation loop.

const ModelType = @import("../../model/Model.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const AgentInputType = @import("../../agents/AgentInput.zig");
const std = @import("std");
const Capture = @import("Capture.zig");
const SidebarAnimationHandler = @import("SidebarAnimationHandler.zig");
const VersionType = @import("../../model/Version.zig");

pub const Activity = enum {
    active,
    inactive,
};

fn reconcileAgent(model: *ModelType, revision: u64, status: AgentStatusType) !void {
    const agent: AgentInputType = .{
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(try handler.synchronize() == .inactive);
    try std.testing.expect((try handler.tick()) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(VersionType{}, model.version());
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());
}

test "SidebarAnimationHandler synchronizes without mutation and commits before rearming" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    try reconcileAgent(&model, 1, .working);
    var capture: Capture = .{ .model = &model };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(try handler.synchronize() == .active);
    try std.testing.expectEqual(VersionType{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.expected_revision = 1;
    capture.expected_frame = 1;
    const change = (try handler.tick()).?;

    try std.testing.expectEqual(@as(u8, 1), change.frame);
    try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(VersionType{
        .agents = 1,
        .sidebar_animation = 1,
    }, model.version());
}

test "SidebarAnimationHandler preserves a committed frame after scheduler failure" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    try reconcileAgent(&model, 1, .working);
    var capture: Capture = .{
        .model = &model,
        .fail = true,
    };
    var handler: SidebarAnimationHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expectError(error.AnimationScheduleFailed, handler.synchronize());

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(VersionType{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());

    capture.expected_revision = 1;
    capture.expected_frame = 1;
    try std.testing.expectError(error.AnimationScheduleFailed, handler.tick());

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(u8, 1), model.sidebarAnimationFrame());
    try std.testing.expectEqual(VersionType{
        .agents = 1,
        .sidebar_animation = 1,
    }, model.version());
}
