const OwnedNotification = @This();
const source_namespace = @import("outbox_support.zig");
request_id: source_namespace.schema.RequestId,
level: source_namespace.schema.NotificationLevel,
duration_ms: u32,
target: source_namespace.schema.NotificationTarget,
title: [source_namespace.schema.max_notification_title_bytes]u8 = undefined,
title_len: u8,
message: [source_namespace.schema.max_notification_message_bytes]u8 = undefined,
message_len: u8,

pub fn view(value: *const OwnedNotification) source_namespace.schema.ShowNotification {
    return .{
        .request_id = value.request_id,
        .notification = .{
            .level = value.level,
            .duration_ms = value.duration_ms,
            .target = value.target,
            .title = value.title[0..value.title_len],
            .message = value.message[0..value.message_len],
        },
    };
}
