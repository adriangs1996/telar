//! Application policy for the model-owned sidebar animation loop.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const Activity = enum {
    active,
    inactive,
};

pub const Effects = struct {
    context: *anyopaque,
    schedule: *const fn (*anyopaque) anyerror!void,
};

pub const SidebarAnimationHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Ensures an active animation has one future tick without changing its
    /// visible frame.
    ///
    /// ```zig
    /// _ = try handler.synchronize();
    /// ```
    pub fn synchronize(handler: *SidebarAnimationHandler) !Activity {
        if (!handler.model.sidebarAnimationActive()) {
            return .inactive;
        }

        try handler.effects.schedule(handler.effects.context);
        return .active;
    }

    /// Commits one visible frame before rearming the animation scheduler.
    ///
    /// ```zig
    /// _ = try handler.tick();
    /// ```
    pub fn tick(handler: *SidebarAnimationHandler) !?client_model.SidebarAnimationChange {
        const change = handler.model.advanceSidebarAnimation() orelse return null;

        try handler.effects.schedule(handler.effects.context);
        return change;
    }
};

const Capture = struct {
    model: *const client_model.Model,
    expected_revision: u64 = 0,
    expected_frame: u8 = 0,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .schedule = schedule };
    }

    fn schedule(raw_context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.calls += 1;
        capture.observed_commit = capture.model.version().sidebar_animation ==
            capture.expected_revision and
            capture.model.sidebarAnimationFrame() == capture.expected_frame;

        if (capture.fail) {
            return error.AnimationScheduleFailed;
        }
    }
};

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
