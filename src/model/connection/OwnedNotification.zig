const core = @import("telar-core");
const OwnedNotification = @This();

request_id: core.RequestId,
level: core.NotificationLevel,
duration_ms: u32,
target: core.NotificationTarget,
title: [core.max_notification_title_bytes]u8 = undefined,
title_len: u8,
message: [core.max_notification_message_bytes]u8 = undefined,
message_len: u8,

pub fn view(value: *const OwnedNotification) core.ShowNotification {
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
