const EffectsCapture = @This();
const source_namespace = @import("agent_sound.zig");
const Effects = @import("AgentSoundEffects.zig");
calls: usize = 0,
sound: ?source_namespace.schema.AgentSound = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{ .context = capture, .schedule = schedule };
}

fn schedule(context: *anyopaque, sound: source_namespace.schema.AgentSound) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.sound = sound;

    if (capture.fail) {
        return error.SoundScheduleFailed;
    }
}
