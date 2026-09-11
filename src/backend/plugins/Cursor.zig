const std = @import("std");
const Cursor = @This();

bytes: []const u8,
offset: usize = 0,

pub fn byte(cursor: *Cursor) !u8 {
    if (cursor.offset == cursor.bytes.len) {
        return error.TruncatedFrame;
    }
    defer cursor.offset += 1;
    return cursor.bytes[cursor.offset];
}

pub fn boolean(cursor: *Cursor) !bool {
    return switch (try cursor.byte()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

pub fn int(cursor: *Cursor, comptime T: type) !T {
    if (cursor.bytes.len -| cursor.offset < @sizeOf(T)) {
        return error.TruncatedFrame;
    }
    defer cursor.offset += @sizeOf(T);
    return std.mem.readInt(T, cursor.bytes[cursor.offset..][0..@sizeOf(T)], .little);
}

pub fn sized(cursor: *Cursor) ![]const u8 {
    const len = try cursor.int(u32);
    if (cursor.bytes.len -| cursor.offset < len) {
        return error.TruncatedFrame;
    }
    defer cursor.offset += len;
    return cursor.bytes[cursor.offset..][0..len];
}
