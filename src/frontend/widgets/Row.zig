const goto_picker = @import("goto_picker.zig");
const Row = @This();

text: [goto_picker.max_row_bytes]u8 = undefined,
len: u8 = 0,
selected: bool = false,

pub fn slice(row: *const Row) []const u8 {
    return row.text[0..row.len];
}
