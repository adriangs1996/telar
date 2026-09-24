//! A bare Unicode block element, U+2580 through U+259F, independent of the configured font.
const Block = @This();

codepoint: u21,

/// Keeps combining and variation sequences together in the normal font path.
/// Example: `const block = BlockElement.parse("█") orelse return;`
pub fn parse(text: []const u8) ?Block {
    if (text.len != 3 or text[0] != 0xe2 or text[1] != 0x96 or text[2] < 0x80 or text[2] > 0x9f) {
        return null;
    }

    return .{ .codepoint = 0x2580 + @as(u21, text[2] & 31) };
}

test "all 32 block codepoints and only bare complete graphemes are procedural" {
    const std = @import("std");
    for (0x2580..0x25a0) |codepoint| {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(codepoint), &bytes);
        const block = parse(bytes[0..length]).?;
        try std.testing.expectEqual(@as(u21, @intCast(codepoint)), block.codepoint);
    }

    for ([_][]const u8{ "", "x", "\u{257f}", "\u{25a0}", "\xe2\x96", "\xe2\x96\x7f", "\xe2\x96\xa0", "██", "█\u{301}", "▀\u{fe0f}" }) |text| {
        try std.testing.expectEqual(@as(?Block, null), parse(text));
    }
}
