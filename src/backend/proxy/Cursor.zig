const std = @import("std");
const Cursor = @This();

bytes: []const u8,
index: usize = 0,

pub fn left(cursor: Cursor) usize {
    return cursor.bytes.len - cursor.index;
}

pub fn take(cursor: *Cursor, len: usize) ![]const u8 {
    if (cursor.left() < len) {
        return error.Truncated;
    }
    defer cursor.index += len;
    return cursor.bytes[cursor.index..][0..len];
}

pub fn byte(cursor: *Cursor) !u8 {
    return (try cursor.take(1))[0];
}

pub fn big16(cursor: *Cursor) !u16 {
    return std.mem.readInt(u16, (try cursor.take(2))[0..2], .big);
}
