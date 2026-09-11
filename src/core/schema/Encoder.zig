const Encoder = @This();
const std = @import("std");
buffer: []u8,
index: usize = 0,

pub fn init(buffer: []u8) Encoder {
    return .{ .buffer = buffer };
}

pub fn writeByte(encoder: *Encoder, value: u8) error{BufferTooSmall}!void {
    if (encoder.index == encoder.buffer.len) {
        return error.BufferTooSmall;
    }
    encoder.buffer[encoder.index] = value;
    encoder.index += 1;
}

pub fn writeInt(encoder: *Encoder, comptime T: type, value: T) error{BufferTooSmall}!void {
    const size = @sizeOf(T);

    if (encoder.buffer.len - encoder.index < size) {
        return error.BufferTooSmall;
    }

    std.mem.writeInt(T, encoder.buffer[encoder.index..][0..size], value, .little);
    encoder.index += size;
}

pub fn writeBytes(encoder: *Encoder, bytes: []const u8) error{BufferTooSmall}!void {
    if (encoder.buffer.len - encoder.index < bytes.len) {
        return error.BufferTooSmall;
    }

    std.mem.copyForwards(u8, encoder.buffer[encoder.index..][0..bytes.len], bytes);
    encoder.index += bytes.len;
}

pub fn writeSized16(encoder: *Encoder, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u16)) {
        return error.LengthOverflow;
    }

    try encoder.writeInt(u16, @intCast(bytes.len));
    try encoder.writeBytes(bytes);
}

pub fn writeSized32(encoder: *Encoder, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) {
        return error.LengthOverflow;
    }

    try encoder.writeInt(u32, @intCast(bytes.len));
    try encoder.writeBytes(bytes);
}

pub fn finish(encoder: *Encoder) []const u8 {
    return encoder.buffer[0..encoder.index];
}
