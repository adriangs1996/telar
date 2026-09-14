const core = @import("telar-core");
const WrappedLines = @This();

text: []const u8,
width: u16,
index: usize = 0,
finished: bool = false,

/// Borrows one complete visible line, splitting only at grapheme boundaries.
/// Canvas sanitizes control characters before creating glyphs.
/// Example: `while (lines.next()) |line| try canvas.text(area, label(line));`.
pub fn next(lines: *WrappedLines) ?[]const u8 {
    if (lines.finished or lines.width == 0) {
        return null;
    }

    const start = lines.index;
    var used: u16 = 0;
    var iterator: core.GraphemeIterator = .{ .bytes = lines.text, .index = lines.index };
    while (iterator.index < lines.text.len) {
        const before = iterator.index;
        if (lines.text[before] == '\n' or lines.text[before] == '\r') {
            lines.index = before + 1;
            if (lines.text[before] == '\r' and lines.index < lines.text.len and lines.text[lines.index] == '\n') {
                lines.index += 1;
            }

            return lines.text[start..before];
        }

        const cluster = iterator.next().?;
        if (@as(u32, used) + cluster.width > lines.width) {
            lines.index = if (used == 0) iterator.index else before;
            lines.finished = lines.index == lines.text.len;
            return lines.text[start..lines.index];
        }

        used += cluster.width;
    }

    lines.index = lines.text.len;
    lines.finished = true;
    return lines.text[start..];
}

/// Counts with the exact same wrapping used for painting.
/// Example: `const maximum_scroll = lines.count() -| visible_rows;`.
pub fn count(lines: WrappedLines) u32 {
    var copy = lines;
    var total: u32 = 0;
    while (copy.next() != null) {
        total += 1;
    }

    return total;
}
