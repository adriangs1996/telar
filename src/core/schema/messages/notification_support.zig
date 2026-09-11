//! User-visible notifications raised by a client or the runtime.

const ShowNotification = @import("ShowNotification.zig");
const codec = @import("../codec.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const DecoderType = @import("../Decoder.zig");
const Notification = @import("Notification.zig");
const std = @import("std");
const types = @import("../types.zig");
const NotificationShown = @import("NotificationShown.zig");

pub fn encodeShowNotification(buffer: []u8, message: ShowNotification) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.show_notification));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeNotificationBody(&encoder, message.notification);
    return encoder.finish();
}

pub fn decodeShowNotification(decoder: *DecoderType) !ShowNotification {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .notification = try decodeNotification(decoder),
    };
}

pub fn encodeNotification(buffer: []u8, message: Notification) ![]const u8 {
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.notification));
    try encodeNotificationBody(&encoder, message);
    return encoder.finish();
}

pub fn decodeNotification(decoder: *DecoderType) !Notification {
    const level = std.enums.fromInt(types.NotificationLevel, try decoder.readByte()) orelse
        return error.InvalidNotificationLevel;
    const duration_ms = try decoder.readInt(u32);
    const target: types.NotificationTarget = switch (try decoder.readByte()) {
        0 => .none,
        1 => .{ .pane = try id.pane(try decoder.readInt(u64)) },
        2 => .{ .tab = try id.tab(try decoder.readInt(u64)) },
        3 => .{ .workspace = try id.workspace(try decoder.readInt(u64)) },
        else => return error.InvalidNotificationTarget,
    };
    const notification: Notification = .{
        .level = level,
        .duration_ms = duration_ms,
        .target = target,
        .title = try decoder.readSized16(),
        .message = try decoder.readSized16(),
    };
    try validateNotification(notification);
    return notification;
}

pub fn encodeNotificationShown(buffer: []u8, message: NotificationShown) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ServerTag.notification_shown),
        buffer,
        message,
    );
}

fn encodeNotificationBody(encoder: *EncoderType, notification: Notification) !void {
    try validateNotification(notification);
    try encoder.writeByte(@intFromEnum(notification.level));
    try encoder.writeInt(u32, notification.duration_ms);
    switch (notification.target) {
        .none => try encoder.writeByte(0),
        .pane => |pane_id| {
            try codec.validatePaneId(pane_id);
            try encoder.writeByte(1);
            try encoder.writeInt(u64, id.raw(pane_id));
        },
        .tab => |tab_id| {
            if (tab_id == .invalid) {
                return error.InvalidTabId;
            }
            try encoder.writeByte(2);
            try encoder.writeInt(u64, id.raw(tab_id));
        },
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) {
                return error.InvalidWorkspaceId;
            }
            try encoder.writeByte(3);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
    }
    try encoder.writeSized16(notification.title);
    try encoder.writeSized16(notification.message);
}

fn validateNotification(notification: Notification) !void {
    if (notification.duration_ms < types.min_notification_duration_ms or
        notification.duration_ms > types.max_notification_duration_ms)
    {
        return error.InvalidNotificationDuration;
    }
    try validateNotificationText(notification.title, types.max_notification_title_bytes, false);
    try validateNotificationText(notification.message, types.max_notification_message_bytes, true);
}

fn validateNotificationText(bytes: []const u8, maximum: usize, empty_allowed: bool) !void {
    try codec.validateBytes(bytes, maximum, empty_allowed);
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return error.InvalidUtf8;
    }
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f)
        return error.InvalidNotificationText;
}
