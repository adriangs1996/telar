//! Owned semantic keys shared by host decoding, routing and child encoding.

const std = @import("std");

pub const Key = @import("Key.zig");

pub const Char = @import("Char.zig");

pub const Mouse = @import("Mouse.zig");

test "semantic key owns its scalar after the input buffer changes" {
    var bytes = [_]u8{ 0xc3, 0xb1 };
    const key = Key.plain(.{ .char = Char.init(&bytes) });
    @memset(&bytes, 0);
    try std.testing.expectEqualStrings("ñ", key.code.char.slice());
}
