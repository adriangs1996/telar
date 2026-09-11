const std = @import("std");
const Diagnostic = @This();

buffer: [512]u8 = undefined,
len: usize = 0,

pub fn message(diagnostic: *const Diagnostic) []const u8 {
    return diagnostic.buffer[0..diagnostic.len];
}

pub fn set(diagnostic: *Diagnostic, comptime format: []const u8, args: anytype) void {
    const rendered = std.fmt.bufPrint(&diagnostic.buffer, format, args) catch
        "configuration error";
    diagnostic.len = rendered.len;
}
