const NavigationCapture = @This();
const notification_capability = @import("../../root.zig").notifications;
const TimerEffects = @import("TimerEffects.zig");
const ActivationEffects = @import("ActivationEffects.zig");
calls: usize = 0,
target: ?notification_capability.Target = null,
fail: bool = false,

pub fn effects(capture: *NavigationCapture, timers: TimerEffects) ActivationEffects {
    return .{
        .timers = timers,
        .context = capture,
        .navigate = navigate,
    };
}

fn navigate(context: *anyopaque, target: notification_capability.Target) !void {
    const capture: *NavigationCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.target = target;

    if (capture.fail) {
        return error.NavigationFailed;
    }
}
