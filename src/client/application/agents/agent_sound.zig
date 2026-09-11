//! Application policy for one runtime-owned agent sound.

const AgentKeyType = @import("../../agents/AgentKey.zig");
const AgentInputType = @import("../../agents/AgentInput.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const EffectsCapture = @import("EffectsCapture.zig");
const HandleAgentSoundHandler = @import("HandleAgentSoundHandler.zig");
const AgentSoundType = @import("telar-core").AgentSound;
const VersionType = @import("../../model/Version.zig");

pub const Outcome = enum {
    accepted,
    stale,
};

fn agentInput(key: AgentKeyType) AgentInputType {
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const key: AgentKeyType = .{
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
    try std.testing.expectEqual(AgentSoundType.ready, capture.sound.?);
    try std.testing.expectEqual(VersionType{ .agents = 1 }, model.version());
}

test "HandleAgentSoundHandler propagates effect failure for a current identity" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const key: AgentKeyType = .{
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
