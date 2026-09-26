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
