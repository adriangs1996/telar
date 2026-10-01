const core = @import("telar-core");
const Notification = @This();

pub const Input = @import("Input.zig");

level: core.NotificationLevel = .info,
duration_ms: u32 = core.default_notification_duration_ms,
target: core.NotificationTarget = .none,
title_bytes: [core.max_notification_title_bytes]u8 = @splat(0),
title_len: u16,
message_bytes: [core.max_notification_message_bytes]u8 = @splat(0),
message_len: u16,

/// Copies a validated notification into bounded inline storage.
/// For example: `const notification = try Notification.init(.{ .title = "Ready", .message = "Open result" });`.
pub fn init(input: Input) !Notification {
    // Reuse the wire validator so Lua and plugins cannot construct a value
    // that the runtime will reject after the effect batch is committed.
    var validation_buffer: [
        1 + 8 + 1 + 4 + 1 + 8 + 2 +
            core.max_notification_title_bytes + 2 +
            core.max_notification_message_bytes
    ]u8 = undefined;
    _ = try core.encodeShowNotification(
        &validation_buffer,
        .{
            .request_id = @enumFromInt(1),
            .notification = .{
                .level = input.level,
                .duration_ms = input.duration_ms,
                .target = input.target,
                .title = input.title,
                .message = input.message,
            },
        },
    );
    var value: Notification = .{
        .level = input.level,
        .duration_ms = input.duration_ms,
        .target = input.target,
        .title_len = @intCast(input.title.len),
        .message_len = @intCast(input.message.len),
    };
    @memcpy(value.title_bytes[0..input.title.len], input.title);
    @memcpy(value.message_bytes[0..input.message.len], input.message);
    return value;
}

pub fn title(self: *const Notification) []const u8 {
    return self.title_bytes[0..self.title_len];
}

pub fn message(self: *const Notification) []const u8 {
    return self.message_bytes[0..self.message_len];
}
