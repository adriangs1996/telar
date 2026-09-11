//! Application policy for one runtime-owned agent sound.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../root.zig").agents;
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const Command = @import("Command.zig");

pub const Effects = @import("AgentSoundEffects.zig");

pub const Outcome = enum {
    accepted,
    stale,
};

pub const HandleAgentSoundHandler = @import("HandleAgentSoundHandler.zig");

const EffectsCapture = @import("EffectsCapture.zig");

fn agentInput(key: agents.AgentKey) agents.AgentInput {
    return .{
        .key = key,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    };
}

test "HandleAgentSoundHandler accepts only an exact current identity" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const key: agents.AgentKey = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
    };
    const agent = agentInput(key);
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });
    var capture: EffectsCapture = .{};
    var handler: HandleAgentSoundHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const stale = try handler.execute(.{
        .key = .{ .pane_id = key.pane_id, .pane_generation = 2 },
        .sound = .needs_input,
    });

    try std.testing.expectEqual(Outcome.stale, stale);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const accepted = try handler.execute(.{ .key = key, .sound = .ready });

    try std.testing.expectEqual(Outcome.accepted, accepted);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(schema.AgentSound.ready, capture.sound.?);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
}

test "HandleAgentSoundHandler propagates effect failure for a current identity" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const key: agents.AgentKey = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
    };
    const agent = agentInput(key);
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });
    var capture: EffectsCapture = .{ .fail = true };
    var handler: HandleAgentSoundHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.SoundScheduleFailed,
        handler.execute(.{ .key = key, .sound = .needs_input }),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
