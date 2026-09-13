//! A bare Unicode box-drawing grapheme, independent of the configured font.
const Box = @This();

codepoint: u21,

/// Keeps combining and variation sequences together in the normal font path.
/// Example: `const box = BoxDrawing.parse("╭") orelse return;`
pub fn parse(text: []const u8) ?Box {
    if (text.len != 3 or text[0] != 0xe2 or (text[1] != 0x94 and text[1] != 0x95) or text[2] < 0x80 or text[2] > 0xbf) {
        return null;
    }

    return .{ .codepoint = 0x2500 + (@as(u21, text[1] & 1) << 6) + (text[2] & 63) };
}

pub fn curve(box: Box) ?u3 {
    return if (box.codepoint >= 0x256d and box.codepoint <= 0x2573) @intCast(box.codepoint - 0x256d) else null;
}

test "all 128 box codepoints and only bare complete graphemes are procedural" {
    const std = @import("std");
    for (0x2500..0x2580) |codepoint| {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(codepoint), &bytes);
        const box = parse(bytes[0..length]).?;
        try std.testing.expectEqual(@as(u21, @intCast(codepoint)), box.codepoint);
        try std.testing.expectEqual(codepoint >= 0x256d and codepoint <= 0x2573, box.curve() != null);
    }

    for ([_][]const u8{ "", "x", "\u{24ff}", "\u{2580}", "\xe2\x94", "\xe2\x94\x7f", "\xe2\x95\xc0", "││", "│\u{301}", "╭\u{fe0f}" }) |text| {
        try std.testing.expectEqual(@as(?Box, null), parse(text));
    }
}
