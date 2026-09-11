const max_notification_title_bytes = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes = @import("telar-core").max_notification_message_bytes;
const host = @import("host.zig");
/// One owned, sanitized payload handed to the system-notification worker.
const Payload = @This();

title: [max_notification_title_bytes]u8 = undefined,
title_len: u8 = 0,
message: [max_notification_message_bytes]u8 = undefined,
message_len: u8 = 0,

pub fn init(title: []const u8, message: []const u8) Payload {
    var payload: Payload = .{};
    payload.title_len = host.copySanitized(&payload.title, title);
    payload.message_len = host.copySanitized(&payload.message, message);
    return payload;
}

pub fn titleSlice(payload: *const Payload) []const u8 {
    return payload.title[0..payload.title_len];
}

pub fn messageSlice(payload: *const Payload) []const u8 {
    return payload.message[0..payload.message_len];
}
