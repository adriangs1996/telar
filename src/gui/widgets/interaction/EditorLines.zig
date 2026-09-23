//! Word wrapping in measured pixels for proportional editors or terminal cells.
const core = @import("telar-core");
const Font = @import("EditorFont.zig");
const Lines = @This();

text: []const u8,
width: u16,
font: ?Font = null,
index: usize = 0,
finished: bool = false,
paragraph_start: usize = 0,
paragraph_end: usize = 0,
paragraph_ready: bool = false,
paragraph_positions: [Font.max_bytes + 1]u32 = undefined,
line_positions: [Font.max_bytes + 1]u32 = undefined,
line_start: usize = 0,
line_end: usize = 0,

/// Preserves every byte and wraps whole words when they fit on the next line.
/// Example: `while (lines.next()) |line| try paint(line);`
pub fn next(self: *Lines) ?[]const u8 {
    if (self.finished or self.width == 0) {
        return null;
    }

    if (self.font != null and self.text.len <= Font.max_bytes) {
        return self.nextShaped();
    }

    const start = self.index;
    self.line_start = start;
    var used: u32 = 0;
    var boundary = start;
    var iterator: core.GraphemeIterator = .{ .bytes = self.text, .index = start };
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

/// Uses the current complete line's shaping, including internal ligature stops.
/// Example: `const x = lines.position(selection - line_start);`
pub fn position(self: *const Lines, offset: usize) u32 {
    const at = @min(offset, self.line_end - self.line_start);
    return if (self.font != null and self.text.len <= Font.max_bytes) self.line_positions[at] else core.measure(self.text[self.line_start .. self.line_start + at]);
}

fn nextShaped(self: *Lines) []const u8 {
    const start = self.index;
    if (!self.paragraph_ready or start > self.paragraph_end) {
        self.paragraph_start = start;
        self.paragraph_end = start;
        while (self.paragraph_end < self.text.len and self.text[self.paragraph_end] != '\r' and self.text[self.paragraph_end] != '\n') {
            self.paragraph_end += 1;
        }

        const paragraph = self.text[start..self.paragraph_end];
        self.font.?.positions(paragraph, self.paragraph_positions[0 .. paragraph.len + 1]);
        self.paragraph_ready = true;
    }

    const relative = start - self.paragraph_start;
    var end = start + fittingEnd(self.text[start..self.paragraph_end], .{ .positions = self.paragraph_positions[relative .. self.paragraph_end - self.paragraph_start + 1], .width = self.width });
    var adjusted = false;
    while (true) {
        const line = self.text[start..end];
        self.font.?.positions(line, self.line_positions[0 .. line.len + 1]);
        const fit = fittingEnd(line, .{ .positions = self.line_positions[0 .. line.len + 1], .width = self.width });
        if (fit == line.len) {
            break;
        }

        // Context can change at a hard word split. One exact correction is
        // followed by geometric reduction, bounding all further reshaping.
        var limit = fit;
        if (adjusted) {
            limit = @min(limit, line.len / 2);
        }

        var iterator: core.GraphemeIterator = .{ .bytes = line };
        var boundary: usize = 0;
        while (iterator.next() != null) {
            if (iterator.index > limit and boundary != 0) {
                break;
            }

            boundary = iterator.index;
            if (boundary >= limit) {
                break;
            }
        }

        if (boundary == line.len) {
            break;
        }

        end = start + boundary;
        adjusted = true;
    }

    self.line_start = start;
    self.line_end = end;
    self.index = end;
    if (end == self.paragraph_end and end < self.text.len) {
        self.index += 1;
        if (self.text[end] == '\r' and self.index < self.text.len and self.text[self.index] == '\n') {
            self.index += 1;
        }
    } else {
        self.finished = end == self.text.len;
    }

    return self.text[start..end];
}

fn fittingEnd(text: []const u8, input: @import("LineFit.zig")) usize {
    var iterator: core.GraphemeIterator = .{ .bytes = text };
    var boundary: usize = 0;
    var before: usize = 0;
    while (iterator.next()) |cluster| {
        const from = input.positions[0];
        const to = input.positions[iterator.index];
        const width = @max(from, to) - @min(from, to);
        if (width > input.width) {
            return if (before == 0) iterator.index else if (boundary != 0) boundary else before;
        }

        if (cluster.bytes[0] == ' ' or cluster.bytes[0] == '\t') {
            boundary = iterator.index;
        }

        before = iterator.index;
    }

    return text.len;
}
