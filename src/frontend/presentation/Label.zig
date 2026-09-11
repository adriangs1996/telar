const pane_labels = @import("pane_labels.zig");
const std = @import("std");
const Label = @This();

offset: u16,
width: u16,
selected: bool,
bytes: [pane_labels.max_text_bytes]u8 = undefined,
len: u8 = 0,

pub fn text(label: *const Label) []const u8 {
    return label.bytes[0..label.len];
}

pub fn sameText(a: *const Label, b: *const Label) bool {
    return a.offset == b.offset and a.width == b.width and
        std.mem.eql(u8, a.text(), b.text());
}
