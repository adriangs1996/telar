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
pub fn next(lines: *Lines) ?[]const u8 {
    if (lines.finished or lines.width == 0) {
        return null;
    }

    if (lines.font != null and lines.text.len <= Font.max_bytes) {
        return lines.nextShaped();
    }

    const start = lines.index;
    lines.line_start = start;
    var used: u32 = 0;
    var boundary = start;
    var iterator: core.GraphemeIterator = .{ .bytes = lines.text, .index = start };
    while (iterator.index < lines.text.len) {
        const before = iterator.index;
        if (lines.text[before] == '\n' or lines.text[before] == '\r') {
            lines.index = before + 1;
            if (lines.text[before] == '\r' and lines.index < lines.text.len and lines.text[lines.index] == '\n') {
                lines.index += 1;
            }

            lines.line_end = before;
            return lines.text[start..before];
        }

        const cluster = iterator.next().?;
        const advance = cluster.width;
        if (used + advance > lines.width) {
            lines.index = if (before == start) iterator.index else if (boundary > start) boundary else before;
            lines.finished = lines.index == lines.text.len;
            lines.line_end = lines.index;
            return lines.text[start..lines.index];
        }

        used += advance;
        if (cluster.bytes[0] == ' ' or cluster.bytes[0] == '\t') {
            boundary = iterator.index;
        }
    }

    lines.index = lines.text.len;
    lines.finished = true;
    lines.line_end = lines.text.len;
    return lines.text[start..];
}

/// Uses the current complete line's shaping, including internal ligature stops.
/// Example: `const x = lines.position(selection - line_start);`
pub fn position(lines: *const Lines, offset: usize) u32 {
    const at = @min(offset, lines.line_end - lines.line_start);
    return if (lines.font != null and lines.text.len <= Font.max_bytes) lines.line_positions[at] else core.measure(lines.text[lines.line_start .. lines.line_start + at]);
}

fn nextShaped(lines: *Lines) []const u8 {
    const start = lines.index;
    if (!lines.paragraph_ready or start > lines.paragraph_end) {
        lines.paragraph_start = start;
        lines.paragraph_end = start;
        while (lines.paragraph_end < lines.text.len and lines.text[lines.paragraph_end] != '\r' and lines.text[lines.paragraph_end] != '\n') {
            lines.paragraph_end += 1;
        }

        const paragraph = lines.text[start..lines.paragraph_end];
        lines.font.?.positions(paragraph, lines.paragraph_positions[0 .. paragraph.len + 1]);
        lines.paragraph_ready = true;
    }

    const relative = start - lines.paragraph_start;
    var end = start + fittingEnd(lines.text[start..lines.paragraph_end], .{ .positions = lines.paragraph_positions[relative .. lines.paragraph_end - lines.paragraph_start + 1], .width = lines.width });
    var adjusted = false;
    while (true) {
        const line = lines.text[start..end];
        lines.font.?.positions(line, lines.line_positions[0 .. line.len + 1]);
        const fit = fittingEnd(line, .{ .positions = lines.line_positions[0 .. line.len + 1], .width = lines.width });
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

    lines.line_start = start;
    lines.line_end = end;
    lines.index = end;
    if (end == lines.paragraph_end and end < lines.text.len) {
        lines.index += 1;
        if (lines.text[end] == '\r' and lines.index < lines.text.len and lines.text[lines.index] == '\n') {
            lines.index += 1;
        }
    } else {
        lines.finished = end == lines.text.len;
    }

    return lines.text[start..end];
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
