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
pub fn next(self: *Cells) ?[]const u8 {
    if (self.finished or self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    const start = self.index;
    while (self.index < self.text.len) {
        const byte = self.text[self.index];
        if (byte == '\\' and self.index + 1 < self.text.len) {
            self.index += 2;
            continue;
        }

        self.index += 1;
        if (byte == '|') {
            return std.mem.trim(u8, self.text[start .. self.index - 1], " \t");
        }
    }

    self.finished = true;
    return std.mem.trim(u8, self.text[start..], " \t");
}
