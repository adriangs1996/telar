/// One owned, sanitized payload handed to the system-notification worker.
const Payload = @This();
const center = @import("telar-client").notifications;
const source_namespace = @import("host.zig");
title: [center.max_title_bytes]u8 = undefined,
title_len: u8 = 0,
message: [center.max_message_bytes]u8 = undefined,
message_len: u8 = 0,

pub fn init(title: []const u8, message: []const u8) Payload {
    var payload: Payload = .{};
    payload.title_len = source_namespace.copySanitized(&payload.title, title);
    payload.message_len = source_namespace.copySanitized(&payload.message, message);
    return payload;
}

pub fn titleSlice(payload: *const Payload) []const u8 {
    return payload.title[0..payload.title_len];
}

pub fn messageSlice(payload: *const Payload) []const u8 {
    return payload.message[0..payload.message_len];
}
