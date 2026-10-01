//! One owned, sanitized notice handed to a host channel: the outer terminal's
//! OSC 9 or the operating system's notification service.
const core = @import("telar-core");
const std = @import("std");
const NotificationPayload = @This();

title: [core.max_notification_title_bytes]u8 = undefined,
title_len: u16 = 0,
message: [core.max_notification_message_bytes]u8 = undefined,
message_len: u16 = 0,

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
/// Text past the storage is cut on a UTF-8 boundary.
fn copySanitized(storage: []u8, text: []const u8) u16 {
    var len: usize = 0;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\\') {
            continue;
        }

        if (len == storage.len) {
            // Drop a character the bound split, continuation bytes first.
            if ((byte & 0xc0) == 0x80) {
                while (len > 0 and (storage[len - 1] & 0xc0) == 0x80) {
                    len -= 1;
                }

                if (len > 0 and storage[len - 1] >= 0xc0) {
                    len -= 1;
                }
            }

            break;
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

test "a payload past its bound is cut on a UTF-8 boundary" {
    const title = "a" ** (core.max_notification_title_bytes - 1) ++ "é";
    const payload = NotificationPayload.init(title, "é" ** core.max_notification_message_bytes);

    try std.testing.expectEqualStrings("a" ** (core.max_notification_title_bytes - 1), payload.titleSlice());
    try std.testing.expect(std.unicode.utf8ValidateSlice(payload.messageSlice()));
    try std.testing.expectEqual(@as(usize, core.max_notification_message_bytes), payload.messageSlice().len);
}
