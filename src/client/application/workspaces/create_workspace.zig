//! Application use cases for requesting and confirming workspace creation.

const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const std = @import("std");

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_tab_label_bytes_module) {
        return error.InvalidWorkspaceName;
    }
    if (!std.unicode.utf8ValidateSlice(name)) {
        return error.InvalidUtf8;
    }
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidWorkspaceName;
        }
    }
}
