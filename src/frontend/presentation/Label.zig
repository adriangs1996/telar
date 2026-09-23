const pane_labels = @import("pane_labels.zig");
const std = @import("std");
const Label = @This();

offset: u16,
width: u16,
selected: bool,
bytes: [pane_labels.max_text_bytes]u8 = undefined,
len: u8 = 0,

pub fn text(self: *const Label) []const u8 {
    return self.bytes[0..self.len];
}

pub fn sameText(self: *const Label, b: *const Label) bool {
    return self.offset == b.offset and self.width == b.width and
        std.mem.eql(u8, self.text(), b.text());
}
