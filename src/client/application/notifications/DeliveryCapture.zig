const InputType = @import("../../notifications/NotificationInput.zig");
const DeliveryEffects = @import("DeliveryEffects.zig");
const DeliveryCapture = @This();

calls: usize = 0,
input: ?InputType = null,
failure: ?anyerror = null,

pub fn effects(capture: *DeliveryCapture) DeliveryEffects {
    return .{ .context = capture, .publish = publish };
}

fn publish(context: *anyopaque, input: InputType) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.input = input;

    if (capture.failure) |failure| {
        return failure;
    }
}
