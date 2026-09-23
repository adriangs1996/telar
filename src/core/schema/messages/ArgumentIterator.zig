const Decoder = @import("../Decoder.zig");
const codec = @import("../codec.zig");
const std = @import("std");
const ArgumentIterator = @This();

decoder: Decoder,
remaining: u16,
index: u16 = 0,

pub fn next(self: *ArgumentIterator) !?[]const u8 {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    defer self.index += 1;
    const argument = try self.decoder.readSized16();
    try codec.validateBytes(argument, std.math.maxInt(u16), self.index != 0);
    return argument;
}
