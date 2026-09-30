//! The text a bar component may carry: UTF-8 without terminal controls, so
//! nothing a configuration returns can reach a terminal as an escape.
const std = @import("std");

const first_printable: u8 = 0x20;
const delete_control: u8 = 0x7f;

/// Example: `if (!bar_text.valid(label)) return error.InvalidBarText;`
pub fn valid(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) {
        return false;
    }

    for (value) |byte| {
        if (byte < first_printable or byte == delete_control) {
            return false;
        }
    }

    return true;
}

/// The longest start of `value` of at most `max_bytes` that does not end
/// inside a UTF-8 sequence.
///
/// ```zig
/// const shown = bar_text.prefix(reason, max_error_bytes);
/// ```
pub fn prefix(value: []const u8, max_bytes: usize) []const u8 {
    var len = @min(value.len, max_bytes);
    while (len > 0 and len < value.len and value[len] & continuation_mask == continuation_bits) {
        len -= 1;
    }

    return value[0..len];
}

const continuation_mask: u8 = 0b1100_0000;
const continuation_bits: u8 = 0b1000_0000;

test "a prefix never splits a character" {
    try std.testing.expectEqualStrings("ab", prefix("ab", 8));
    try std.testing.expectEqualStrings("a", prefix("aé", 2));
    try std.testing.expectEqualStrings("aé", prefix("aéb", 3));
    try std.testing.expectEqualStrings("", prefix("€", 2));
}
