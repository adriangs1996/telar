const std = @import("std");
const Cursor = @This();

bytes: []const u8,
index: usize = 0,

pub fn left(self: Cursor) usize {
    return self.bytes.len - self.index;
}

pub fn take(self: *Cursor, len: usize) ![]const u8 {
    if (self.left() < len) {
        return error.Truncated;
    }
    defer self.index += len;
    return self.bytes[self.index..][0..len];
}

pub fn byte(self: *Cursor) !u8 {
    return (try self.take(1))[0];
}

pub fn big16(self: *Cursor) !u16 {
    return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
}
