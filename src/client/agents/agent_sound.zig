//! Agent sound: plays agent sounds one at a time on a worker.
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");

const AgentSoundOutcome = enum { stale, accepted };

/// Releases one playback worker and schedules its coalesced successor.
/// Host playback errors drop that sound without stopping the queue.
/// Example: `try agent_sound.completeAgentSound(client, result);`
pub fn completeAgentSound(client: *Client, result: anyerror!void) !void {
    _ = result catch {};
    const next = client.model.sound_playback.complete() orelse return;

    try startAgentSound(client, next);
}

/// Translates one runtime sound and applies it to an exact current agent.
pub fn applyAgentSound(client: *Client, notification: core.AgentSoundNotification) !AgentSoundOutcome {
    if (!(client.model.agent_snapshot.find(
        .{
            .pane_id = notification.pane_id,
            .pane_generation = notification.pane_generation,
        },
    ) != null)) {
        return .stale;
    }

    switch (client.model.sound_playback.request(notification.sound)) {
        .ignored, .queued => {},
        .start => |kind| try startAgentSound(client, kind),
    }

    return .accepted;
}

fn startAgentSound(client: *Client, kind: core.AgentSound) !void {
    client.to_background.push(.{ .sound = kind }) catch |err| {
        client.model.sound_playback.schedulingFailed();
        return err;
    };
}
