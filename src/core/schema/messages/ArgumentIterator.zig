const DecoderType = @import("../Decoder.zig");
const codec = @import("../codec.zig");
const std = @import("std");
const ArgumentIterator = @This();

decoder: DecoderType,
remaining: u16,
index: u16 = 0,

pub fn next(iterator: *ArgumentIterator) !?[]const u8 {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    defer iterator.index += 1;
    const argument = try iterator.decoder.readSized16();
    try codec.validateBytes(argument, std.math.maxInt(u16), iterator.index != 0);
    return argument;
}
