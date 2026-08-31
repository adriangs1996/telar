//! Adapts runtime agent-sound messages to client application policy.

const core = @import("telar-core");
const sound_capability = @import("../sound/root.zig");
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

/// Releases one playback worker and schedules its coalesced successor.
/// Host playback errors drop that sound without stopping the queue.
///
/// ```zig
/// try handlePlayed(client, result);
/// ```
pub fn handlePlayed(client: *Client, result: anyerror!void) !void {
    _ = result catch {};
    const next = client.sound_playback.complete() orelse return;

    try start(client, next);
}

fn schedule(context: *anyopaque, sound: schema.AgentSound) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    switch (client.sound_playback.request(sound)) {
        .ignored, .queued => {},
        .start => |kind| try start(client, kind),
    }
}

fn start(client: *Client, kind: schema.AgentSound) !void {
    client.select.concurrent(.sound_played, sound_capability.play, .{ client.io, kind }) catch |err| {
        client.sound_playback.schedulingFailed();
        return err;
    };
}
