const AgentSoundType = @import("telar-core").AgentSound;
/// Host playback of one semantic agent sound. The adapter starts the work and
/// reports its completion through its own event loop; the client owns the
/// queue and coalescing policy.
const SoundPort = @This();

context: *anyopaque,
play: *const fn (*anyopaque, AgentSoundType) anyerror!void,

/// Starts one playback. Example: `try client.sound_port.start(.ready);`.
pub fn start(port: SoundPort, kind: AgentSoundType) !void {
    return port.play(port.context, kind);
}
