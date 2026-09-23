//! Visible message text selected by source byte offsets, with no retained slices.
const MessageTable = @import("MessageTable.zig");
const std = @import("std");
const Selection = @This();

text: []const u8,
markdown: bool = true,
code: bool = false,
range: [2]u32,

/// Writes displayed text in the half-open source range without Markdown syntax.
/// Visual wrapping adds no newlines; code and literal messages retain their bytes.
/// Example: `try selection.write(&clipboard_writer);`
pub fn write(self: Selection, writer: *std.Io.Writer) !void {
    var selected = self;
    selected.range = self.bounds();
    if (selected.range[0] == selected.range[1]) {
        return;
    }

    if (selected.code or !selected.markdown) {
        try writer.writeAll(selected.text[selected.range[0]..selected.range[1]]);
        return;
    }

    var blocks: @import("MessageBlocks.zig") = .{ .text = selected.text };
    while (blocks.index < selected.range[1]) {
        const block = blocks.next() orelse break;
        if (block.kind == .table) {
            const table = MessageTable.parse(block.text).?;
            try selected.writeRow(writer, table.rowCells(table.header));
            var rows: @import("MessageBlocks.zig") = .{ .text = table.body, .markdown = false };
            while (rows.next()) |row| {
                try selected.writeRow(writer, table.rowCells(row.text));
            }

            continue;
        }

        if (block.kind == .code) {
            try selected.writeSlice(writer, block.text);
            if (blocks.index < selected.text.len) {
                const end = @intFromPtr(block.text.ptr) - @intFromPtr(selected.text.ptr) + block.text.len;
                try selected.writeSlice(writer, selected.lineBreak(end));
            }

            continue;
        }

        var spans: @import("MessageSpans.zig") = .{ .text = block.text };
        while (spans.next()) |span| {
            try selected.writeSlice(writer, span.text);
        }

        var end = blocks.index;
        if (end > 0 and selected.text[end - 1] == '\n') {
            end -= 1;
            if (end > 0 and selected.text[end - 1] == '\r') {
                end -= 1;
            }
        } else if (end > 0 and selected.text[end - 1] == '\r') {
            end -= 1;
        }

        try selected.writeSlice(writer, selected.text[end..blocks.index]);
    }
}

fn bounds(self: Selection) [2]u32 {
    var start = @min(@min(self.range[0], self.range[1]), self.text.len);
    var end = @min(@max(self.range[0], self.range[1]), self.text.len);
    while (start < end and self.text[start] & 0xc0 == 0x80) {
        start += 1;
    }

    while (end > start and end < self.text.len and self.text[end] & 0xc0 == 0x80) {
        end -= 1;
    }

    return .{ @intCast(start), @intCast(end) };
}

fn writeRow(self: Selection, writer: *std.Io.Writer, row: @import("MessageTableCells.zig")) !void {
    var cells = row;
    var first = true;
    while (cells.next()) |cell| {
        const offset = @intFromPtr(cell.ptr) - @intFromPtr(self.text.ptr);
        if (!first and offset > self.range[0] and offset < self.range[1]) {
            try writer.writeByte('\t');
        }

        first = false;
        var spans: @import("MessageSpans.zig") = .{ .text = cell, .table_cell = true };
        while (spans.next()) |span| {
            try self.writeSlice(writer, span.text);
        }
    }

    const end = @intFromPtr(row.source.ptr) - @intFromPtr(self.text.ptr) + row.source.len;
    try self.writeSlice(writer, self.lineBreak(end));
}

fn writeSlice(self: Selection, writer: *std.Io.Writer, visible: []const u8) !void {
    if (visible.len == 0) {
        return;
    }

    const offset = @intFromPtr(visible.ptr) - @intFromPtr(self.text.ptr);
    const start = @max(offset, self.range[0]);
    const end = @min(offset + visible.len, self.range[1]);
    if (start < end) {
        try writer.writeAll(self.text[start..end]);
    }
}

fn lineBreak(self: Selection, at: usize) []const u8 {
    var end = at;
    if (end < self.text.len and self.text[end] == '\r') {
        end += 1;
    }

    if (end < self.text.len and self.text[end] == '\n') {
        end += 1;
    }

    return self.text[at..end];
}

fn expectText(self: Selection, expected: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try self.write(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "selection copies inline labels and styles without hidden Markdown or destinations" {
    const source = "Read [**documentation** and `input`](https://example.test/private \"Title\") with *care*.";
    try expectText(.{ .text = source, .range = .{ 0, source.len } }, "Read documentation and input with care.");
    const destination = std.mem.indexOf(u8, source, "https://").?;
    try expectText(.{ .text = source, .range = .{ @intCast(destination), @intCast(destination + 10) } }, "");
    const label = std.mem.indexOf(u8, source, "documentation").?;
    const code = std.mem.indexOf(u8, source, "input").?;
    try expectText(.{ .text = source, .range = .{ @intCast(label + 3), @intCast(code + 2) } }, "umentation and in");
}

test "selection preserves logical lines and skips block decorations and fence labels" {
    const source = "## Result\r\n\r\n- First\n12. Second\n> Note\n---\n```zig\nconst x = `raw`;\n\nreturn x;\n```\nDone";
    try expectText(.{ .text = source, .range = .{ 0, source.len } }, "Result\r\n\r\nFirst\nSecond\nNote\n\nconst x = `raw`;\n\nreturn x;\nDone");
    const fence = std.mem.indexOf(u8, source, "```zig").?;
    try expectText(.{ .text = source, .range = .{ @intCast(fence), @intCast(fence + 6) } }, "");
}

test "selection copies literal code and user text without reparsing their content" {
    const source = "# **literal**\r\n[not a link](hidden)\n```zig\n";
    try expectText(.{ .text = source, .markdown = false, .range = .{ 0, source.len } }, source);
    try expectText(.{ .text = source, .code = true, .range = .{ 0, source.len } }, source);
    const fenced = "```text\r\n[raw](destination)\r\n**raw**\r\n```";
    try expectText(.{ .text = fenced, .range = .{ 0, fenced.len } }, "[raw](destination)\r\n**raw**");
}

test "selection follows streaming parser and escaped punctuation visible in the message" {
    const source = "\\[literal\\] <https://example.test> [unfinished](url";
    try expectText(.{ .text = source, .range = .{ 0, source.len } }, "[literal] https://example.test [unfinished](url");
    const fenced = "```text\n[raw](destination)\n**unfinished";
    try expectText(.{ .text = fenced, .range = .{ 0, fenced.len } }, "[raw](destination)\n**unfinished");
}

test "selection is bounded and never emits partial UTF8 codepoints" {
    const source = "aé🙂z";
    try expectText(.{ .text = source, .range = .{ 100, 0 } }, source);
    try expectText(.{ .text = source, .range = .{ 2, 7 } }, "🙂");
    try expectText(.{ .text = source, .range = .{ 1, 6 } }, "é");
    try expectText(.{ .text = source, .range = .{ 2, 6 } }, "");
    try expectText(.{ .text = source, .range = .{ 3, 3 } }, "");
}

test "selection propagates output capacity failure without allocating" {
    var buffer: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const selection: Selection = .{ .text = "**long**", .range = .{ 0, 8 } };
    try std.testing.expectError(error.WriteFailed, selection.write(&writer));
}

test "table selection copies cells as tab separated text without delimiter rows" {
    const source = "| Name | Price |\r\n| --- | ---: |\r\n| **Visit** | 50 € |\r\n| [Link](https://example.test) | 60 € |\r\n\r\nAfter";
    try expectText(.{ .text = source, .range = .{ 0, source.len } }, "Name\tPrice\r\nVisit\t50 €\r\nLink\t60 €\r\n\r\nAfter");
    const start = std.mem.indexOf(u8, source, "Visit").?;
    const end = std.mem.indexOf(u8, source, "50 €").? + "50 €".len;
    try expectText(.{ .text = source, .range = .{ @intCast(start), @intCast(end) } }, "Visit\t50 €");
    const delimiter = std.mem.indexOf(u8, source, "| ---").?;
    try expectText(.{ .text = source, .range = .{ @intCast(delimiter), @intCast(delimiter + 14) } }, "");
}

test "table copying omits surplus cells and decodes pipes inside inline code" {
    const source = "| A | B |\n| --- | --- |\n| `a\\|b` | c\\|d | hidden |";
    try expectText(.{ .text = source, .range = .{ 0, source.len } }, "A\tB\na|b\tc|d");
    const code = "`a\\|b`";
    try expectText(.{ .text = code, .range = .{ 0, code.len } }, "a\\|b");
}
