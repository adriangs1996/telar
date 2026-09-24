const std = @import("std");
const Encoder = @This();

buffer: []u8,
index: usize = 0,

/// Writes into `buffer` from its start.
///
/// ```zig
/// var encoder = Encoder.init(&buffer);
/// ```
pub fn init(buffer: []u8) Encoder {
    return .{ .buffer = buffer };
}

/// Appends one byte.
///
/// ```zig
/// try encoder.writeByte(7);
/// ```
pub fn writeByte(self: *Encoder, value: u8) error{BufferTooSmall}!void {
    if (self.index == self.buffer.len) {
        return error.BufferTooSmall;
    }
    self.buffer[self.index] = value;
    self.index += 1;
}

/// Appends an integer in little-endian order.
///
/// ```zig
/// try encoder.writeInt(u32, 0x12345678);
/// ```
pub fn writeInt(self: *Encoder, comptime T: type, value: T) error{BufferTooSmall}!void {
    const size = @sizeOf(T);

    if (self.buffer.len - self.index < size) {
        return error.BufferTooSmall;
    }

    std.mem.writeInt(T, self.buffer[self.index..][0..size], value, .little);
    self.index += size;
}

/// Appends raw bytes. `bytes` may overlap the buffer.
///
/// ```zig
/// try encoder.writeBytes("telar");
/// ```
pub fn writeBytes(self: *Encoder, bytes: []const u8) error{BufferTooSmall}!void {
    if (self.buffer.len - self.index < bytes.len) {
        return error.BufferTooSmall;
    }

    @memmove(self.buffer[self.index..][0..bytes.len], bytes);
    self.index += bytes.len;
}

/// Appends a u16 length prefix and the bytes.
///
/// ```zig
/// try encoder.writeSized16("telar");
/// ```
pub fn writeSized16(self: *Encoder, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u16)) {
        return error.LengthOverflow;
    }

    try self.writeInt(u16, @intCast(bytes.len));
    try self.writeBytes(bytes);
}

/// Appends a u32 length prefix and the bytes.
///
/// ```zig
/// try encoder.writeSized32(payload);
/// ```
pub fn writeSized32(self: *Encoder, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) {
        return error.LengthOverflow;
    }

    try self.writeInt(u32, @intCast(bytes.len));
    try self.writeBytes(bytes);
}

/// Returns the bytes written so far.
///
/// ```zig
/// const payload = encoder.finish();
/// ```
pub fn finish(self: *Encoder) []const u8 {
    return self.buffer[0..self.index];
}
