const ArgumentIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("launch.zig");
const std = @import("std");
decoder: wire.Decoder,
remaining: u16,
index: u16 = 0,

pub fn next(iterator: *ArgumentIterator) !?[]const u8 {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    defer iterator.index += 1;
    const argument = try iterator.decoder.readSized16();
    try source_namespace.validateBytes(argument, std.math.maxInt(u16), iterator.index != 0);
    return argument;
}
