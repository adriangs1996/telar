//! Converts a local file URI into an owned path suitable for an argv entry.

const std = @import("std");

pub fn validateEscapes(text: []const u8) !void {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(
        u8,
        text,
        index,
        '%',
    )) |percent| {
        if (text.len - percent < 3 or !std.ascii.isHex(text[percent + 1]) or !std.ascii.isHex(text[percent + 2])) {
            return error.InvalidFileLink;
        }

        index = percent + 3;
    }
}
