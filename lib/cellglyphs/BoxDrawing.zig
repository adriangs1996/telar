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

pub fn curve(self: Box) ?u3 {
    return if (self.codepoint >= 0x256d and self.codepoint <= 0x2573) @intCast(self.codepoint - 0x256d) else null;
}
