const NotificationLevelType = @import("telar-core").NotificationLevel;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const max_notification_title_bytes_module = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes_module = @import("telar-core").max_notification_message_bytes;
const NotificationType = @import("telar-core").Notification;
const std = @import("std");
const PendingNotification = @This();

level: NotificationLevelType,
duration_ms: u32,
target: NotificationTargetType,
title_bytes: [max_notification_title_bytes_module]u8 = undefined,
title_len: u8,
message_bytes: [max_notification_message_bytes_module]u8 = undefined,
message_len: u8,

pub fn init(notification: NotificationType) PendingNotification {
    std.debug.assert(notification.title.len <= max_notification_title_bytes_module);
    std.debug.assert(notification.message.len <= max_notification_message_bytes_module);
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

pub fn view(notification: *const PendingNotification) NotificationType {
    return .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .target = notification.target,
        .title = notification.title_bytes[0..notification.title_len],
        .message = notification.message_bytes[0..notification.message_len],
    };
}
