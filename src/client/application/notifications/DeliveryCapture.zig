const DeliveryCapture = @This();
const notification_capability = @import("../../root.zig").notifications;
const DeliveryEffects = @import("DeliveryEffects.zig");
calls: usize = 0,
input: ?notification_capability.Input = null,
failure: ?anyerror = null,

pub fn effects(capture: *DeliveryCapture) DeliveryEffects {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, input: notification_capability.Input) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.input = input;

    if (capture.failure) |failure| {
        return failure;
    }
}
