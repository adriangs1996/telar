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
