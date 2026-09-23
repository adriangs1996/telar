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

pub fn view(self: *const OwnedNotification) core.ShowNotification {
    return .{
        .request_id = self.request_id,
        .notification = .{
            .level = self.level,
            .duration_ms = self.duration_ms,
            .target = self.target,
            .title = self.title[0..self.title_len],
            .message = self.message[0..self.message_len],
        },
    };
}
