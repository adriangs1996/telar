const Notification = @This();
const source_namespace = @import("action.zig");
pub const Input = struct {
    level: source_namespace.schema.NotificationLevel = .info,
    duration_ms: u32 = source_namespace.schema.default_notification_duration_ms,
    target: source_namespace.schema.NotificationTarget = .none,
    title: []const u8,
    message: []const u8,
};

level: source_namespace.schema.NotificationLevel = .info,
duration_ms: u32 = source_namespace.schema.default_notification_duration_ms,
target: source_namespace.schema.NotificationTarget = .none,
title_bytes: [source_namespace.schema.max_notification_title_bytes]u8 = @splat(0),
title_len: u8,
message_bytes: [source_namespace.schema.max_notification_message_bytes]u8 = @splat(0),
message_len: u8,

/// Copies a validated notification into bounded inline storage.
/// For example: `const notification = try Notification.init(.{ .title = "Ready", .message = "Open result" });`.
pub fn init(input: Input) !Notification {
    // Reuse the wire validator so Lua and plugins cannot construct a value
    // that the runtime will reject after the effect batch is committed.
    var validation_buffer: [
        1 + 8 + 1 + 4 + 1 + 8 + 2 +
            source_namespace.schema.max_notification_title_bytes + 2 +
            source_namespace.schema.max_notification_message_bytes
    ]u8 = undefined;
    _ = try source_namespace.schema.encodeShowNotification(&validation_buffer, .{
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
