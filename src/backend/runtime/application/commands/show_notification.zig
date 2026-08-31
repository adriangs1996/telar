//! Application command for broadcasting one bounded notification.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const ShowNotification = struct {
    /// Borrowed only for the synchronous `execute` call.
    notification: schema.Notification,
};

pub const ShowNotificationResult = struct {
    delivered_clients: u8,
};

pub const NotificationPublisher = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, schema.Notification) u8,

    /// Offers the notification to every eligible client and returns the exact
    /// number whose bounded delivery queue accepted it.
    ///
    /// ```zig
    /// const delivered = publisher.publish(notification);
    /// ```
    pub fn publish(publisher: NotificationPublisher, notification: schema.Notification) u8 {
        return publisher.publish_fn(publisher.context, notification);
    }
};

pub const ShowNotificationExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, ShowNotification) ShowNotificationResult,

    /// Executes the bound notification use case synchronously.
    ///
    /// ```zig
    /// const result = executor.execute(.{ .notification = notification });
    /// ```
    pub fn execute(executor: ShowNotificationExecutor, command: ShowNotification) ShowNotificationResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const ShowNotificationHandler = struct {
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
};

const PublicationCapture = struct {
    delivered_clients: u8,
    call_count: usize = 0,
    level: schema.NotificationLevel = .info,
    duration_ms: u32 = 0,
    target: schema.NotificationTarget = .none,
    title: [schema.max_notification_title_bytes]u8 = undefined,
    title_len: usize = 0,
    message: [schema.max_notification_message_bytes]u8 = undefined,
    message_len: usize = 0,

    fn publisher(capture: *PublicationCapture) NotificationPublisher {
        return .{ .context = capture, .publish_fn = publish };
    }

    fn publish(context: *anyopaque, notification: schema.Notification) u8 {
        const capture: *PublicationCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        capture.level = notification.level;
        capture.duration_ms = notification.duration_ms;
        capture.target = notification.target;
        capture.title_len = notification.title.len;
        @memcpy(capture.title[0..notification.title.len], notification.title);
        capture.message_len = notification.message.len;
        @memcpy(capture.message[0..notification.message.len], notification.message);
        return capture.delivered_clients;
    }

    fn titleSlice(capture: *const PublicationCapture) []const u8 {
        return capture.title[0..capture.title_len];
    }

    fn messageSlice(capture: *const PublicationCapture) []const u8 {
        return capture.message[0..capture.message_len];
    }
};

test "ShowNotificationHandler publishes one owned bounded notification" {
    var capture: PublicationCapture = .{ .delivered_clients = 3 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };

    const result = handler.executor().execute(.{ .notification = .{
        .level = .success,
        .duration_ms = 2500,
        .target = .{ .pane = try schema.id.pane(42) },
        .title = &title,
        .message = &message,
    } });
    @memset(&title, 'x');
    @memset(&message, 'x');

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 3), result.delivered_clients);
    try std.testing.expectEqual(schema.NotificationLevel.success, capture.level);
    try std.testing.expectEqual(@as(u32, 2500), capture.duration_ms);
    try std.testing.expectEqual(try schema.id.pane(42), capture.target.pane);
    try std.testing.expectEqualStrings("Build", capture.titleSlice());
    try std.testing.expectEqualStrings("Done", capture.messageSlice());
}

test "ShowNotificationHandler preserves a zero-recipient result" {
    var capture: PublicationCapture = .{ .delivered_clients = 0 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };

    const result = handler.execute(.{ .notification = .{ .title = "Nobody" } });

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 0), result.delivered_clients);
}
