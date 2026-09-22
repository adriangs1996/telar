const core = @import("telar-core");
const std = @import("std");
const Label = @This();

buffer: [core.max_foreground_name_bytes + 32]u8 = undefined,
len: usize,
width: u16,

pub fn init(name: []const u8, index: usize) Label {
    var label: Label = .{ .len = 0, .width = 0 };
    const text = std.fmt.bufPrint(&label.buffer, " {d} {s} ", .{
        index + 1,
        if (name.len == 0) "shell" else name,
    }) catch unreachable;
    label.len = text.len;
    label.width = core.measure(text);
    return label;
}
