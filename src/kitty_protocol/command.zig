//! Bounded formatting shared by Kitty command encoders.

const std = @import("std");

const Io = std.Io;

pub fn print(writer: *Io.Writer, comptime format: []const u8, args: anytype) Io.Writer.Error!usize {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    try writer.writeAll(text);
    return text.len;
}
