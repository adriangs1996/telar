const RequestIdType = @import("telar-core").RequestId;
const NotificationLevelType = @import("telar-core").NotificationLevel;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const max_notification_title_bytes_module = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes_module = @import("telar-core").max_notification_message_bytes;
const ShowNotificationType = @import("telar-core").ShowNotification;
const OwnedNotification = @This();

request_id: RequestIdType,
level: NotificationLevelType,
duration_ms: u32,
target: NotificationTargetType,
title: [max_notification_title_bytes_module]u8 = undefined,
title_len: u8,
message: [max_notification_message_bytes_module]u8 = undefined,
message_len: u8,

pub fn view(value: *const OwnedNotification) ShowNotificationType {
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
