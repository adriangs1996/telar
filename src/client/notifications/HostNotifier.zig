const data = @import("model");
/// Surfaces one published notice outside the in-app center. The adapter
/// decides how `terminal` and `system` reach the user; `telar` never arrives.
const HostNotifier = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, data.NotificationDelivery, data.NotificationInput) anyerror!void,

/// Example: `try client.notifier.notify(.system, input);`.
pub fn notify(port: HostNotifier, channel: data.NotificationDelivery, input: data.NotificationInput) !void {
    return port.deliver(port.context, channel, input);
}
