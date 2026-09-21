//! Application use cases for requesting and confirming a tab rename.

const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const std = @import("std");

pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > max_tab_label_bytes_module) {
        return error.InvalidTabLabel;
    }
    if (!std.unicode.utf8ValidateSlice(label)) {
        return error.InvalidUtf8;
    }
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidTabLabel;
        }
    }
}
