const core = @import("telar-core");
const std = @import("std");
const PendingNotification = @This();

level: core.NotificationLevel,
duration_ms: u32,
target: core.NotificationTarget,
title_bytes: [core.max_notification_title_bytes]u8 = undefined,
title_len: u8,
message_bytes: [core.max_notification_message_bytes]u8 = undefined,
message_len: u8,
link_bytes: [core.max_notification_link_bytes]u8 = undefined,
link_len: u16 = 0,

pub fn init(notification: core.Notification) PendingNotification {
    std.debug.assert(notification.title.len <= core.max_notification_title_bytes);
    std.debug.assert(notification.message.len <= core.max_notification_message_bytes);
    std.debug.assert(notification.link.len <= core.max_notification_link_bytes);
    var pending: PendingNotification = .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .target = notification.target,
        .title_len = @intCast(notification.title.len),
        .message_len = @intCast(notification.message.len),
        .link_len = @intCast(notification.link.len),
    };
    @memcpy(pending.title_bytes[0..notification.title.len], notification.title);
    @memcpy(pending.message_bytes[0..notification.message.len], notification.message);
    @memcpy(pending.link_bytes[0..notification.link.len], notification.link);
    return pending;
}

pub fn view(self: *const PendingNotification) core.Notification {
    return .{
        .level = self.level,
        .duration_ms = self.duration_ms,
        .target = self.target,
        .title = self.title_bytes[0..self.title_len],
        .message = self.message_bytes[0..self.message_len],
        .link = self.link_bytes[0..self.link_len],
    };
}
