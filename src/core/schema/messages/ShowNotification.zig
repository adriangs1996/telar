const ShowNotification = @This();
const source_namespace = @import("notification_support.zig");
const Notification = @import("Notification.zig");
request_id: source_namespace.RequestId,
notification: Notification,
