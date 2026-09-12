const DeliveryType = @import("notifications.zig").Delivery;
const InputType = @import("NotificationInput.zig");
/// Surfaces one published notice outside the in-app center. The adapter
/// decides how `terminal` and `system` reach the user; `telar` never arrives.
const HostNotifier = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, DeliveryType, InputType) anyerror!void,

/// Example: `try client.notifier.notify(.system, input);`.
pub fn notify(port: HostNotifier, channel: DeliveryType, input: InputType) !void {
    return port.deliver(port.context, channel, input);
}
