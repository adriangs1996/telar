const InputType = @import("../../notifications/NotificationInput.zig");
const ClipboardImageDeliveryEffects = @import("ClipboardImageDeliveryEffects.zig");
const Capture = @This();

calls: usize = 0,
input: ?InputType = null,
fail: bool = false,

pub fn effects(capture: *Capture) ClipboardImageDeliveryEffects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: InputType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.input = input;

    if (capture.fail) {
        return error.NotificationPublicationFailed;
    }
}
