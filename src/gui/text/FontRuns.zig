//! Groups whole graphemes by face, retaining contextual shaping within each span.
const cellglyphs = @import("cellglyphs");
const cellgrid = @import("cellgrid");
const font_id = @import("font_id.zig");
const FontSet = @import("FontSet.zig");
const FontRun = @import("FontRun.zig");
const Box = cellglyphs.BoxDrawing;
const Block = cellglyphs.BlockElement;
const Braille = cellglyphs.Braille;
const FontRuns = @This();

fonts: *const FontSet,
iterator: cellgrid.GraphemeIterator,
/// The face a caller asked for; graphemes it lacks follow the terminal chain.
preferred: font_id.Id = .primary,

/// Borrows slices of the original UTF-8; unsupported clusters remain in primary.
/// Consecutive graphemes of the preferred face share one span; every other
/// grapheme is its own span so fitted fallback ink keeps one cell advance.
/// Example: `while (runs.next()) |run| { ... }`
pub fn next(self: *FontRuns) ?FontRun {
    const start = self.iterator.index;
    const first = self.iterator.next() orelse return null;
    if (Braille.parse(first.bytes)) |pattern| {
        return .{ .text = self.iterator.bytes[start..self.iterator.index], .source = .{ .braille = pattern }, .columns = first.width };
    }

    if (Box.parse(first.bytes)) |box| {
        return .{ .text = self.iterator.bytes[start..self.iterator.index], .source = .{ .box = box }, .columns = first.width };
    }

    if (Block.parse(first.bytes)) |block| {
        return .{ .text = self.iterator.bytes[start..self.iterator.index], .source = .{ .block = block }, .columns = first.width };
    }

    const id = self.fonts.source(first.bytes, self.preferred);
    if (id != self.preferred) {
        return .{ .text = self.iterator.bytes[start..self.iterator.index], .source = .{ .font = id }, .columns = first.width, .preferred = self.preferred };
    }

    var columns: u32 = first.width;
    while (true) {
        const previous = self.iterator.index;
        const cluster = self.iterator.next() orelse break;
        if (Braille.parse(cluster.bytes) != null or Box.parse(cluster.bytes) != null or Block.parse(cluster.bytes) != null or self.fonts.source(cluster.bytes, self.preferred) != id) {
            self.iterator.index = previous;
            break;
        }

        columns += cluster.width;
    }

    return .{ .text = self.iterator.bytes[start..self.iterator.index], .source = .{ .font = id }, .columns = columns, .preferred = self.preferred };
}
