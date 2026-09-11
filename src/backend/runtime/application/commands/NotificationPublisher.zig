const NotificationType = @import("telar-core").Notification;
const NotificationPublisher = @This();

context: *anyopaque,
publish_fn: *const fn (*anyopaque, NotificationType) u8,

/// Offers the notification to every eligible client and returns the exact
/// number whose bounded delivery queue accepted it.
///
/// ```zig
/// const delivered = publisher.publish(notification);
/// ```
pub fn publish(publisher: NotificationPublisher, notification: NotificationType) u8 {
    return publisher.publish_fn(publisher.context, notification);
}
