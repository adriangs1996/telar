//! Bounded formatting shared by Kitty command encoders.

const std = @import("std");

pub fn print(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!usize {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    try writer.writeAll(text);
    return text.len;
}
