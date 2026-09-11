const NotificationPublisher = @This();
const source_namespace = @import("show_notification.zig");
context: *anyopaque,
publish_fn: *const fn (*anyopaque, source_namespace.schema.Notification) u8,

/// Offers the notification to every eligible client and returns the exact
/// number whose bounded delivery queue accepted it.
///
/// ```zig
/// const delivered = publisher.publish(notification);
/// ```
pub fn publish(publisher: NotificationPublisher, notification: source_namespace.schema.Notification) u8 {
    return publisher.publish_fn(publisher.context, notification);
}
