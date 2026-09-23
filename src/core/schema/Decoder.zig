const std = @import("std");
const Decoder = @This();

bytes: []const u8,
index: usize = 0,

pub fn init(bytes: []const u8) Decoder {
    return .{ .bytes = bytes };
}

pub fn readByte(self: *Decoder) error{Truncated}!u8 {
    if (self.index == self.bytes.len) {
        return error.Truncated;
    }

    defer self.index += 1;
    return self.bytes[self.index];
}

pub fn readInt(self: *Decoder, comptime T: type) error{Truncated}!T {
    const size = @sizeOf(T);
    if (self.bytes.len - self.index < size) {
        return error.Truncated;
    }

    defer self.index += size;
    return std.mem.readInt(T, self.bytes[self.index..][0..size], .little);
}

pub fn readBool(self: *Decoder) error{ Truncated, InvalidBoolean }!bool {
    return switch (try self.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

pub fn readBytes(self: *Decoder, length: usize) error{Truncated}![]const u8 {
    if (self.bytes.len - self.index < length) {
        return error.Truncated;
    }

    defer self.index += length;
    return self.bytes[self.index..][0..length];
}

pub fn readSized16(self: *Decoder) error{Truncated}![]const u8 {
    return self.readBytes(try self.readInt(u16));
}

pub fn readSized32(self: *Decoder) error{Truncated}![]const u8 {
    return self.readBytes(try self.readInt(u32));
}

pub fn ensureEnd(self: *const Decoder) error{TrailingBytes}!void {
    if (self.index != self.bytes.len) {
        return error.TrailingBytes;
    }
}

pub fn consumed(self: *const Decoder, start: usize) []const u8 {
    return self.bytes[start..self.index];
}
