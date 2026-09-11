//! Bounds-checked little-endian wire helpers.

const std = @import("std");

pub const Encoder = @import("Encoder.zig");

pub const Decoder = @import("Decoder.zig");

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
