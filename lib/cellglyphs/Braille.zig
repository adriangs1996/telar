//! Procedural Unicode Braille patterns; each bit owns one dot in a 2 by 4 cell.
const gfx = @import("gfx");
const Grid = @import("BrailleGrid.zig");
const Color = gfx.Color;
const QuadList = gfx.QuadList;
const Rect = gfx.Rect;
const Braille = @This();

dots: u8,

/// Accepts exactly one bare Braille grapheme, preserving attached marks for shaping.
/// Example: `const pattern = Braille.parse("\u{2801}") orelse return;`
pub fn parse(text: []const u8) ?Braille {
    if (text.len != 3 or text[0] != 0xe2 or text[1] < 0xa0 or text[1] > 0xa3 or text[2] < 0x80 or text[2] > 0xbf) {
        return null;
    }

    return .{ .dots = ((text[1] & 3) << 6) | (text[2] & 63) };
}

/// Places the dots in `cell`, the cell's rectangle in device pixels, and
/// returns its advance; no font or atlas lookup.
/// Example: `_ = try pattern.paint(cell, color, quads);`
pub fn paint(self: Braille, cell: Rect, color: Color, list: *QuadList) !f32 {
    const grid = try Grid.init(cell);
    if (grid.diameter == 0) {
        return cell.width;
    }

    const columns = [_]u1{ 0, 0, 0, 1, 1, 1, 0, 1 };
    const rows = [_]u2{ 0, 1, 2, 0, 1, 2, 3, 3 };
    for (columns, rows, 0..) |column, row, bit| {
        if (self.dots & (@as(u8, 1) << @intCast(bit)) == 0) {
            continue;
        }

        try list.pushRect(.{ .x = grid.x[column], .y = grid.y[row], .width = grid.diameter, .height = grid.diameter }, color);
    }

    return cell.width;
}
