//! Borrowed table cells. Only unescaped pipes delimit columns, including in code.
const std = @import("std");
const Cells = @This();

text: []const u8,
source: []const u8,
index: usize = 0,
finished: bool = false,
remaining: usize = std.math.maxInt(usize),

/// Removes optional outer pipes without losing empty cells or source offsets.
/// Example: `var cells = MessageTableCells.init("| Name | Value |");`
pub fn init(line: []const u8) Cells {
    var text = std.mem.trim(u8, line, " \t\r");
    if (text.len > 0 and text[0] == '|') {
        text = text[1..];
    }

    if (text.len > 0 and text[text.len - 1] == '|') {
        var slashes: usize = 0;
        var index = text.len - 1;
        while (index > 0 and text[index - 1] == '\\') : (index -= 1) {
            slashes += 1;
        }

        if (slashes % 2 == 0) {
            text = text[0 .. text.len - 1];
        }
    }

    return .{ .text = text, .source = line };
}

/// Example: `while (cells.next()) |cell| try drawCell(cell);`
pub fn next(cells: *Cells) ?[]const u8 {
    if (cells.finished or cells.remaining == 0) {
        return null;
    }

    cells.remaining -= 1;
    const start = cells.index;
    while (cells.index < cells.text.len) {
        const byte = cells.text[cells.index];
        if (byte == '\\' and cells.index + 1 < cells.text.len) {
            cells.index += 2;
            continue;
        }

        cells.index += 1;
        if (byte == '|') {
            return std.mem.trim(u8, cells.text[start .. cells.index - 1], " \t");
        }
    }

    cells.finished = true;
    return std.mem.trim(u8, cells.text[start..], " \t");
}
