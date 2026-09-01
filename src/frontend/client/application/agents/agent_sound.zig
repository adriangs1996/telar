//! Application policy for one runtime-owned agent sound.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const Command = struct {
    key: agents.AgentKey,
    sound: schema.AgentSound,
};

pub const Effects = struct {
    context: *anyopaque,
    schedule: *const fn (*anyopaque, schema.AgentSound) anyerror!void,
};

pub const Outcome = enum {
    accepted,
    stale,
};

pub const HandleAgentSoundHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Applies local sound policy only for an exact current agent identity.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *HandleAgentSoundHandler, command: Command) !Outcome {
        if (!handler.model.knowsAgent(command.key)) {
            return .stale;
        }

        try handler.effects.schedule(handler.effects.context, command.sound);
        return .accepted;
    }
};

const EffectsCapture = struct {
    calls: usize = 0,
    sound: ?schema.AgentSound = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .schedule = schedule };
    }

    fn schedule(context: *anyopaque, sound: schema.AgentSound) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.sound = sound;

        if (capture.fail) {
            return error.SoundScheduleFailed;
        }
    }
};

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
