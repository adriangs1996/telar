const std = @import("std");
const Diagnostic = @This();

buffer: [512]u8 = undefined,
len: usize = 0,

pub fn message(self: *const Diagnostic) []const u8 {
    return self.buffer[0..self.len];
}

pub fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
    const rendered = std.fmt.bufPrint(
        &self.buffer,
        format,
        args,
    ) catch
        "configuration error";
    self.len = rendered.len;
}
