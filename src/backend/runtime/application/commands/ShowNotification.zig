const ShowNotification = @This();
const source_namespace = @import("show_notification.zig");
/// Borrowed only for the synchronous `execute` call.
notification: source_namespace.schema.Notification,
