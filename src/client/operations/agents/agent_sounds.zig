//! Adapts runtime agent-sound messages to client application policy.

const Client = @import("../../AttachedClient.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
pub const Outcome = enum { stale, accepted };
const AgentSoundType = @import("telar-core").AgentSound;

/// Translates one runtime sound and applies it to an exact current agent.
///
/// ```zig
/// const outcome = try apply(client, notification);
/// ```
pub fn apply(client: *Client, notification: AgentSoundNotificationType) !Outcome {
    if (!client.model.knowsAgent(.{ .pane_id = notification.pane_id, .pane_generation = notification.pane_generation })) {
        return .stale;
    }

    switch (client.sound_playback.request(notification.sound)) {
        .ignored, .queued => {},
        .start => |kind| try start(client, kind),
    }
    return .accepted;
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

fn start(client: *Client, kind: AgentSoundType) !void {
    client.sound_port.start(kind) catch |err| {
        client.sound_playback.schedulingFailed();
        return err;
    };
}
