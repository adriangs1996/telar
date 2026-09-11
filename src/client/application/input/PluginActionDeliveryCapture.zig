const Capture = @This();
const client_model = @import("../../root.zig").model;
const notification_capability = @import("../../root.zig").notifications;
const Effects = @import("PluginActionDeliveryEffects.zig");
const std = @import("std");
model: *const client_model.Model,
calls: usize = 0,
input: ?notification_capability.Input = null,
observed_diagnostic: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
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
