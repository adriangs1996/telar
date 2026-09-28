//! Word wrapping in terminal cells.
const cellgrid = @import("cellgrid");
const Lines = @This();

text: []const u8,
width: u16,
index: usize = 0,
finished: bool = false,
line_start: usize = 0,
line_end: usize = 0,

/// Preserves every byte and wraps whole words when they fit on the next line.
/// Example: `while (lines.next()) |line| try paint(line);`
pub fn next(self: *Lines) ?[]const u8 {
    if (self.finished or self.width == 0) {
        return null;
    }

    const start = self.index;
    self.line_start = start;
    var used: u32 = 0;
    var boundary = start;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = self.text, .index = start };
    while (iterator.index < self.text.len) {
        const before = iterator.index;
        if (self.text[before] == '\n' or self.text[before] == '\r') {
            self.index = before + 1;
            if (self.text[before] == '\r' and self.index < self.text.len and self.text[self.index] == '\n') {
                self.index += 1;
            }

            self.line_end = before;
            return self.text[start..before];
        }

        const cluster = iterator.next().?;
        const advance = cluster.width;
        if (used + advance > self.width) {
            self.index = if (before == start) iterator.index else if (boundary > start) boundary else before;
            self.finished = self.index == self.text.len;
            self.line_end = self.index;
            return self.text[start..self.index];
        }

        used += advance;
        if (cluster.bytes[0] == ' ' or cluster.bytes[0] == '\t') {
            boundary = iterator.index;
        }
    }

    self.index = self.text.len;
    self.finished = true;
    self.line_end = self.text.len;
    return self.text[start..];
}

/// Measures an offset of the current line in cells.
/// Example: `const x = lines.position(selection - line_start);`
pub fn position(self: *const Lines, offset: usize) u32 {
    const at = @min(offset, self.line_end - self.line_start);
    return cellgrid.text.measure(self.text[self.line_start .. self.line_start + at]);
}
