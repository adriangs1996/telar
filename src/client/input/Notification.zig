const InputType = @import("Input.zig");
const NotificationLevelType = @import("telar-core").NotificationLevel;
const default_notification_duration_ms_module = @import("telar-core").default_notification_duration_ms;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const max_notification_title_bytes_module = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes_module = @import("telar-core").max_notification_message_bytes;
const encodeShowNotification_module = @import("telar-core").encodeShowNotification;
const Notification = @This();

pub const Input = @import("Input.zig");

level: NotificationLevelType = .info,
duration_ms: u32 = default_notification_duration_ms_module,
target: NotificationTargetType = .none,
title_bytes: [max_notification_title_bytes_module]u8 = @splat(0),
title_len: u8,
message_bytes: [max_notification_message_bytes_module]u8 = @splat(0),
message_len: u8,

/// Copies a validated notification into bounded inline storage.
/// For example: `const notification = try Notification.init(.{ .title = "Ready", .message = "Open result" });`.
pub fn init(input: InputType) !Notification {
    // Reuse the wire validator so Lua and plugins cannot construct a value
    // that the runtime will reject after the effect batch is committed.
    var validation_buffer: [
        1 + 8 + 1 + 4 + 1 + 8 + 2 +
            max_notification_title_bytes_module + 2 +
            max_notification_message_bytes_module
    ]u8 = undefined;
    _ = try encodeShowNotification_module(&validation_buffer, .{
        .request_id = @enumFromInt(1),
        .notification = .{
            .level = input.level,
            .duration_ms = input.duration_ms,
            .target = input.target,
            .title = input.title,
            .message = input.message,
        },
    });
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

pub fn title(value: *const Notification) []const u8 {
    return value.title_bytes[0..value.title_len];
}

pub fn message(value: *const Notification) []const u8 {
    return value.message_bytes[0..value.message_len];
}
