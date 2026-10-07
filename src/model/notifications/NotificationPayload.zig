//! One owned, sanitized notice handed to a host channel: the outer terminal's
//! OSC 9 or the operating system's notification service.
const core = @import("telar-core");
const NotificationPayload = @This();

// SAFETY: init sanitizes the title before assigning title_len; titleSlice exposes only that initialized prefix.
title: [core.max_notification_title_bytes]u8 = undefined,
title_len: u16 = 0,
// SAFETY: init sanitizes the message before assigning message_len; messageSlice exposes only that initialized prefix.
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
