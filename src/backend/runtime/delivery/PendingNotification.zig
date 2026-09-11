const PendingNotification = @This();
const source_namespace = @import("response_queue.zig");
const std = @import("std");
level: source_namespace.schema.NotificationLevel,
duration_ms: u32,
target: source_namespace.schema.NotificationTarget,
title_bytes: [source_namespace.schema.max_notification_title_bytes]u8 = undefined,
title_len: u8,
message_bytes: [source_namespace.schema.max_notification_message_bytes]u8 = undefined,
message_len: u8,

pub fn init(notification: source_namespace.schema.Notification) PendingNotification {
    std.debug.assert(notification.title.len <= source_namespace.schema.max_notification_title_bytes);
    std.debug.assert(notification.message.len <= source_namespace.schema.max_notification_message_bytes);
    var pending: PendingNotification = .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .target = notification.target,
        .title_len = @intCast(notification.title.len),
        .message_len = @intCast(notification.message.len),
    };
    @memcpy(pending.title_bytes[0..notification.title.len], notification.title);
    @memcpy(pending.message_bytes[0..notification.message.len], notification.message);
    return pending;
}

pub fn view(notification: *const PendingNotification) source_namespace.schema.Notification {
    return .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .target = notification.target,
        .title = notification.title_bytes[0..notification.title_len],
        .message = notification.message_bytes[0..notification.message_len],
    };
}
