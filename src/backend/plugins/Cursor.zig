const std = @import("std");
const Cursor = @This();

bytes: []const u8,
offset: usize = 0,

pub fn byte(self: *Cursor) !u8 {
    if (self.offset == self.bytes.len) {
        return error.TruncatedFrame;
    }
    defer self.offset += 1;
    return self.bytes[self.offset];
}

pub fn boolean(self: *Cursor) !bool {
    return switch (try self.byte()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

pub fn int(self: *Cursor, comptime T: type) !T {
    if (self.bytes.len -| self.offset < @sizeOf(T)) {
        return error.TruncatedFrame;
    }
    defer self.offset += @sizeOf(T);
    return std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
}

pub fn sized(self: *Cursor) ![]const u8 {
    const len = try self.int(u32);
    if (self.bytes.len -| self.offset < len) {
        return error.TruncatedFrame;
    }
    defer self.offset += len;
    return self.bytes[self.offset..][0..len];
}
