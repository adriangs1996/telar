const NotificationLevelType = @import("telar-core").NotificationLevel;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const max_notification_title_bytes_module = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes_module = @import("telar-core").max_notification_message_bytes;
const NotificationPublisher = @import("NotificationPublisher.zig");
const NotificationType = @import("telar-core").Notification;
const PublicationCapture = @This();

delivered_clients: u8,
call_count: usize = 0,
level: NotificationLevelType = .info,
duration_ms: u32 = 0,
target: NotificationTargetType = .none,
title: [max_notification_title_bytes_module]u8 = undefined,
title_len: usize = 0,
message: [max_notification_message_bytes_module]u8 = undefined,
message_len: usize = 0,

pub fn publisher(capture: *PublicationCapture) NotificationPublisher {
    return .{ .context = capture, .publish_fn = publish };
}

fn publish(context: *anyopaque, notification: NotificationType) u8 {
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

pub fn titleSlice(capture: *const PublicationCapture) []const u8 {
    return capture.title[0..capture.title_len];
}

pub fn messageSlice(capture: *const PublicationCapture) []const u8 {
    return capture.message[0..capture.message_len];
}
