const std = @import("std");
const Decoder = @This();

bytes: []const u8,
index: usize = 0,

pub fn init(bytes: []const u8) Decoder {
    return .{ .bytes = bytes };
}

pub fn readByte(decoder: *Decoder) error{Truncated}!u8 {
    if (decoder.index == decoder.bytes.len) {
        return error.Truncated;
    }

    defer decoder.index += 1;
    return decoder.bytes[decoder.index];
}

pub fn readInt(decoder: *Decoder, comptime T: type) error{Truncated}!T {
    const size = @sizeOf(T);
    if (decoder.bytes.len - decoder.index < size) {
        return error.Truncated;
    }

    defer decoder.index += size;
    return std.mem.readInt(T, decoder.bytes[decoder.index..][0..size], .little);
}

pub fn readBool(decoder: *Decoder) error{ Truncated, InvalidBoolean }!bool {
    return switch (try decoder.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

pub fn readBytes(decoder: *Decoder, length: usize) error{Truncated}![]const u8 {
    if (decoder.bytes.len - decoder.index < length) {
        return error.Truncated;
    }

    defer decoder.index += length;
    return decoder.bytes[decoder.index..][0..length];
}

pub fn readSized16(decoder: *Decoder) error{Truncated}![]const u8 {
    return decoder.readBytes(try decoder.readInt(u16));
}

pub fn readSized32(decoder: *Decoder) error{Truncated}![]const u8 {
    return decoder.readBytes(try decoder.readInt(u32));
}

pub fn ensureEnd(decoder: *const Decoder) error{TrailingBytes}!void {
    if (decoder.index != decoder.bytes.len) {
        return error.TrailingBytes;
    }
}

pub fn consumed(decoder: *const Decoder, start: usize) []const u8 {
    return decoder.bytes[start..decoder.index];
}
