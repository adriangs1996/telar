const ShowNotificationHandler = @This();
const NotificationPublisher = @import("NotificationPublisher.zig");
const ShowNotification = @import("ShowNotification.zig");
const ShowNotificationResult = @import("ShowNotificationResult.zig");
const ShowNotificationExecutor = @import("ShowNotificationExecutor.zig");
notifications: NotificationPublisher,

/// Broadcasts one already-validated notification and reports only clients
/// that accepted an owned copy into their bounded queue.
///
/// ```zig
/// const result = handler.execute(.{ .notification = notification });
/// ```
pub fn execute(handler: *ShowNotificationHandler, command: ShowNotification) ShowNotificationResult {
    return .{
        .delivered_clients = handler.notifications.publish(command.notification),
    };
}

/// Exposes this handler through the application-command interface.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *ShowNotificationHandler) ShowNotificationExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: ShowNotification) ShowNotificationResult {
    const handler: *ShowNotificationHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
