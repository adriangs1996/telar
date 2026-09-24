//! Full-text search query text.
const std = @import("std");

/// FTS5 MATCH parses operators out of raw text; quoting the whole query (and
/// doubling interior quotes) turns it into one literal phrase. `buffer` holds
/// at least `2 * text.len + 2` bytes.
///
/// ```zig
/// const phrase = fts.quote(text, &buffer);
/// ```
pub fn quote(text: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    buffer[len] = '"';
    len += 1;
    for (text) |byte| {
        if (byte == '"') {
            buffer[len] = '"';
            len += 1;
        }

        buffer[len] = byte;
        len += 1;
    }

    buffer[len] = '"';
    len += 1;
    return buffer[0..len];
}

test "a query becomes one literal phrase" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\"say \"\"hi\"\" OR x\"", quote("say \"hi\" OR x", &buffer));
}
