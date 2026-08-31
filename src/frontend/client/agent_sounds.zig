//! Adapts runtime agent-sound messages to client application policy.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const agent_sound = client_application.agent_sound;
const schema = core.schema;

pub const Outcome = agent_sound.Outcome;

/// Translates one runtime sound and applies it to an exact current agent.
///
/// ```zig
/// const outcome = try apply(client, notification);
/// ```
pub fn apply(client: *Client, notification: schema.AgentSoundNotification) !Outcome {
    var use_case: agent_sound.HandleAgentSoundHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .schedule = schedule,
        },
    };

    return use_case.execute(.{
        .key = .{
            .pane_id = notification.pane_id,
            .pane_generation = notification.pane_generation,
        },
        .sound = notification.sound,
    });
}

fn schedule(context: *anyopaque, sound: schema.AgentSound) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.scheduleAgentSound(sound);
}
