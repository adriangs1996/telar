//! Adapts runtime agent-sound messages to client application policy.

const Client = @import("../../Client.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
const ApplicationAgentsAgentSoundOutcome = @import("telar-client").ApplicationAgentsAgentSoundOutcome;
const HandleAgentSoundHandlerType = @import("telar-client").HandleAgentSoundHandler;
const AgentSoundType = @import("telar-core").AgentSound;
const worker = @import("../../../sound/worker.zig");

/// Translates one runtime sound and applies it to an exact current agent.
///
/// ```zig
/// const outcome = try apply(client, notification);
/// ```
pub fn apply(client: *Client, notification: AgentSoundNotificationType) !ApplicationAgentsAgentSoundOutcome {
    var use_case: HandleAgentSoundHandlerType = .{
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

fn schedule(context: *anyopaque, sound: AgentSoundType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    switch (client.sound_playback.request(sound)) {
        .ignored, .queued => {},
        .start => |kind| try start(client, kind),
    }
}

fn start(client: *Client, kind: AgentSoundType) !void {
    client.select.concurrent(.sound_played, worker.play, .{ client.io, kind }) catch |err| {
        client.sound_playback.schedulingFailed();
        return err;
    };
}
