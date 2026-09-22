//! Owned semantic keys shared by host decoding, routing and child encoding.

const data = @import("model");
const std = @import("std");

test "semantic key owns its scalar after the input buffer changes" {
    var bytes = [_]u8{ 0xc3, 0xb1 };
    const key = data.Key.plain(.{ .char = data.Char.init(&bytes) });
    @memset(&bytes, 0);
    try std.testing.expectEqualStrings("ñ", key.code.char.slice());
}
