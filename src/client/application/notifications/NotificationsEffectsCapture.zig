const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const TimerEffects = @import("TimerEffects.zig");
model: *const client_model.Model,
expected_revision: u64 = 0,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) TimerEffects {
    return .{ .context = capture, .reschedule = reschedule };
}

fn reschedule(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.version().notifications == capture.expected_revision;

    if (capture.fail) {
        return error.TimerScheduleFailed;
    }
}
