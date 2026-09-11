const max_foreground_name_bytes_module = @import("telar-core").max_foreground_name_bytes;
const std = @import("std");
const measure_module = @import("telar-core").measure;
const Label = @This();

buffer: [max_foreground_name_bytes_module + 32]u8 = undefined,
len: usize,
width: u16,

pub fn init(name: []const u8, index: usize) Label {
    var label: Label = .{ .len = 0, .width = 0 };
    const text = std.fmt.bufPrint(&label.buffer, " {d} {s} ", .{
        index + 1,
        if (name.len == 0) "shell" else name,
    }) catch unreachable;
    label.len = text.len;
    label.width = measure_module(text);
    return label;
}
