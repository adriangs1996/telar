const std = @import("std");
const Decoder = @This();

bytes: []const u8,
index: usize = 0,

/// Reads `bytes` from their start; the decoder borrows them.
///
/// ```zig
/// var decoder = Decoder.init(payload);
/// ```
pub fn init(bytes: []const u8) Decoder {
    return .{ .bytes = bytes };
}

/// Reads one byte.
///
/// ```zig
/// const tag = try decoder.readByte();
/// ```
pub fn readByte(self: *Decoder) error{Truncated}!u8 {
    if (self.index == self.bytes.len) {
        return error.Truncated;
    }

    defer self.index += 1;
    return self.bytes[self.index];
}

/// Reads a little-endian integer.
///
/// ```zig
/// const length = try decoder.readInt(u32);
/// ```
pub fn readInt(self: *Decoder, comptime T: type) error{Truncated}!T {
    const size = @sizeOf(T);
    if (self.bytes.len - self.index < size) {
        return error.Truncated;
    }

    defer self.index += size;
    return std.mem.readInt(T, self.bytes[self.index..][0..size], .little);
}

/// Reads a byte that must be 0 or 1.
///
/// ```zig
/// const visible = try decoder.readBool();
/// ```
pub fn readBool(self: *Decoder) error{ Truncated, InvalidBoolean }!bool {
    return switch (try self.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

/// Borrows the next `length` bytes.
///
/// ```zig
/// const rgb = try decoder.readBytes(3);
/// ```
pub fn readBytes(self: *Decoder, length: usize) error{Truncated}![]const u8 {
    if (self.bytes.len - self.index < length) {
        return error.Truncated;
    }

    defer self.index += length;
    return self.bytes[self.index..][0..length];
}

/// Borrows bytes behind a u16 length prefix.
///
/// ```zig
/// const name = try decoder.readSized16();
/// ```
pub fn readSized16(self: *Decoder) error{Truncated}![]const u8 {
    return self.readBytes(try self.readInt(u16));
}

/// Borrows bytes behind a u32 length prefix.
///
/// ```zig
/// const payload = try decoder.readSized32();
/// ```
pub fn readSized32(self: *Decoder) error{Truncated}![]const u8 {
    return self.readBytes(try self.readInt(u32));
}

/// Fails when bytes remain after the last read.
///
/// ```zig
/// try decoder.ensureEnd();
/// ```
pub fn ensureEnd(self: *const Decoder) error{TrailingBytes}!void {
    if (self.index != self.bytes.len) {
        return error.TrailingBytes;
    }
}

/// Borrows what was read since `start`, an earlier `index`.
///
/// ```zig
/// const header = decoder.consumed(start);
/// ```
pub fn consumed(self: *const Decoder, start: usize) []const u8 {
    return self.bytes[start..self.index];
}
