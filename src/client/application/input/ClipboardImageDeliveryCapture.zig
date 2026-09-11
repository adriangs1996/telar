const Capture = @This();
const notification_capability = @import("../../root.zig").notifications;
const Effects = @import("ClipboardImageDeliveryEffects.zig");
calls: usize = 0,
input: ?notification_capability.Input = null,
fail: bool = false,

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.input = input;

    if (capture.fail) {
        return error.NotificationPublicationFailed;
    }
}
