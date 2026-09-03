//! Bounds-checked little-endian wire helpers.

const std = @import("std");

pub const Encoder = struct {
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
};

pub const Decoder = struct {
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
};

test "integers and sized byte strings round trip" {
    var buffer: [32]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    try encoder.writeByte(7);
    try encoder.writeInt(u32, 0x12345678);
    try encoder.writeSized16("telar");

    var decoder = Decoder.init(encoder.finish());
    try std.testing.expectEqual(@as(u8, 7), try decoder.readByte());
    try std.testing.expectEqual(@as(u32, 0x12345678), try decoder.readInt(u32));
    try std.testing.expectEqualStrings("telar", try decoder.readSized16());
    try decoder.ensureEnd();
}

test "decoder refuses truncated and trailing data" {
    var decoder = Decoder.init(&.{1});
    try std.testing.expectError(error.Truncated, decoder.readInt(u16));

    var trailing = Decoder.init(&.{ 1, 2 });
    _ = try trailing.readByte();
    try std.testing.expectError(error.TrailingBytes, trailing.ensureEnd());
}
