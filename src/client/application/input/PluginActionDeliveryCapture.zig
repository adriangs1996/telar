const ModelType = @import("../../model/Model.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const PluginActionDeliveryEffects = @import("PluginActionDeliveryEffects.zig");
const std = @import("std");
const Capture = @This();

model: *const ModelType,
calls: usize = 0,
input: ?InputType = null,
observed_diagnostic: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) PluginActionDeliveryEffects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: InputType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.input = input;
    capture.observed_diagnostic = if (capture.model.diagnostic()) |diagnostic|
        std.mem.eql(u8, diagnostic, input.message)
    else
        false;

    if (capture.fail) {
        return error.NotificationPublicationFailed;
    }
}
