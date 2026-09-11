const AgentSoundType = @import("telar-core").AgentSound;
const AgentSoundEffects = @import("AgentSoundEffects.zig");
const EffectsCapture = @This();

calls: usize = 0,
sound: ?AgentSoundType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) AgentSoundEffects {
    return .{ .context = capture, .schedule = schedule };
}

fn schedule(context: *anyopaque, sound: AgentSoundType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.sound = sound;

    if (capture.fail) {
        return error.SoundScheduleFailed;
    }
}
