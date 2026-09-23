//! One owned, sanitized notice handed to a host channel: the outer terminal's
//! OSC 9 or the operating system's notification service.
const core = @import("telar-core");
const std = @import("std");
const NotificationPayload = @This();

title: [core.max_notification_title_bytes]u8 = undefined,
title_len: u8 = 0,
message: [core.max_notification_message_bytes]u8 = undefined,
message_len: u8 = 0,

/// Copies both texts without quotes, control bytes or backslashes.
/// Example: `const payload = NotificationPayload.init(input.title, input.message);`
pub fn init(title: []const u8, message: []const u8) NotificationPayload {
    var payload: NotificationPayload = .{};
    payload.title_len = copySanitized(&payload.title, title);
    payload.message_len = copySanitized(&payload.message, message);
    return payload;
}

pub fn titleSlice(self: *const NotificationPayload) []const u8 {
    return self.title[0..self.title_len];
}

pub fn messageSlice(self: *const NotificationPayload) []const u8 {
    return self.message[0..self.message_len];
}

/// Copies text with quotes, control bytes and backslashes removed, so a
/// payload can be embedded in an OSC string or a quoted script argument.
fn copySanitized(storage: []u8, text: []const u8) u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (len == storage.len) {
            break;
        }

        if (byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\\') {
            continue;
        }

        storage[len] = byte;
        len += 1;
    }

    return @intCast(len);
}

test "payloads drop quotes and control bytes and stay bounded" {
    const payload = NotificationPayload.init("Agent \"done\"\x1b", "line\nbreak\\end");

    try std.testing.expectEqualStrings("Agent done", payload.titleSlice());
    try std.testing.expectEqualStrings("linebreakend", payload.messageSlice());
}
