/// Bounds-checked forward reader over a byte slice. Every length in a
/// ClientHello arrives from the wire, so every step has to be able to fail.
const Cursor = @This();
const std = @import("std");
bytes: []const u8,
idx: usize = 0,

fn left(self: Cursor) usize {
    return self.bytes.len - self.idx;
}

fn take(self: *Cursor, n: usize) ![]const u8 {
    if (self.left() < n) {
        return error.Truncated;
    }
    defer self.idx += n;
    return self.bytes[self.idx..][0..n];
}

fn byte(self: *Cursor) !u8 {
    return (try self.take(1))[0];
}

fn big16(self: *Cursor) !u16 {
    return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
}
