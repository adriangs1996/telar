//! The start of a text that fits a byte limit without splitting a UTF-8
//! sequence, so a bounded copy stays valid text.
const std = @import("std");

/// Mask and value of a UTF-8 continuation byte (`10xxxxxx`).
const continuation_mask = 0xc0;
const continuation = 0x80;

/// The longest prefix of `text` of at most `limit` bytes that ends on a
/// UTF-8 boundary.
///
/// ```zig
/// const title = core.utf8Prefix("café", 4); // "caf"
/// ```
pub fn prefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) {
        return text;
    }

    var end = limit;
    while (end > 0 and (text[end] & continuation_mask) == continuation) {
        end -= 1;
    }

    return text[0..end];
}

test "a prefix ends on a UTF-8 boundary" {
    try std.testing.expectEqualStrings("café", prefix("café", 5));
    try std.testing.expectEqualStrings("caf", prefix("café", 4));
    try std.testing.expectEqualStrings("", prefix("é", 1));
    try std.testing.expectEqualStrings("ab", prefix("abc", 2));
}
