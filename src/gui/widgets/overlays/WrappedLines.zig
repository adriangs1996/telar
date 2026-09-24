const cellgrid = @import("cellgrid");
const WrappedLines = @This();

text: []const u8,
width: u16,
index: usize = 0,
finished: bool = false,

/// Borrows one complete visible line, splitting only at grapheme boundaries.
/// Canvas sanitizes control characters before creating glyphs.
/// Example: `while (lines.next()) |line| try canvas.text(area, label(line));`.
pub fn next(self: *WrappedLines) ?[]const u8 {
    if (self.finished or self.width == 0) {
        return null;
    }

    const start = self.index;
    var used: u16 = 0;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = self.text, .index = self.index };
    while (iterator.index < self.text.len) {
        const before = iterator.index;
        if (self.text[before] == '\n' or self.text[before] == '\r') {
            self.index = before + 1;
            if (self.text[before] == '\r' and self.index < self.text.len and self.text[self.index] == '\n') {
                self.index += 1;
            }

            return self.text[start..before];
        }

        const cluster = iterator.next().?;
        if (@as(u32, used) + cluster.width > self.width) {
            self.index = if (used == 0) iterator.index else before;
            self.finished = self.index == self.text.len;
            return self.text[start..self.index];
        }

        used += cluster.width;
    }

    self.index = self.text.len;
    self.finished = true;
    return self.text[start..];
}

/// Counts with the exact same wrapping used for painting.
/// Example: `const maximum_scroll = lines.count() -| visible_rows;`.
pub fn count(self: WrappedLines) u32 {
    var copy = self;
    var total: u32 = 0;
    while (copy.next() != null) {
        total += 1;
    }

    return total;
}
