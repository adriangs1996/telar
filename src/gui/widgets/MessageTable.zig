//! A bounded, allocation-free table view borrowed from one message snapshot.
const std = @import("std");
const Blocks = @import("MessageBlocks.zig");
const Cells = @import("MessageTableCells.zig");
const Table = @This();

pub const max_columns = 32;
pub const Alignment = enum { left, center, right };

header: []const u8,
body: []const u8,
len: usize,
columns: usize,
alignments: [max_columns]Alignment,

/// Extra body cells are ignored consistently by drawing and selected-text copy.
/// Example: `var cells = table.rowCells(line);`
pub fn rowCells(table: Table, line: []const u8) Cells {
    var cells = Cells.init(line);
    cells.remaining = table.columns;
    return cells;
}

/// A header becomes a table only when its complete delimiter row matches.
/// Unsupported column counts stay literal. Example: `const table = Table.parse(text);`
pub fn parse(text: []const u8) ?Table {
    var lines: Blocks = .{ .text = text, .markdown = false };
    const header = (lines.next() orelse return null).text;
    const delimiter = (lines.next() orelse return null).text;
    if (std.mem.indexOfScalar(u8, header, '|') == null or startsBlock(std.mem.trim(u8, header, " \t"))) {
        return null;
    }

    var table: Table = .{ .header = header, .body = "", .len = 0, .columns = 0, .alignments = undefined };
    var cells = Cells.init(delimiter);
    while (cells.next()) |cell| {
        if (table.columns == max_columns or cell.len == 0) {
            return null;
        }

        const left = cell[0] == ':';
        const right = cell[cell.len - 1] == ':';
        const start: usize = if (left) 1 else 0;
        const end = cell.len - @as(usize, if (right) 1 else 0);
        if (end < start or end - start < 3) {
            return null;
        }

        for (cell[start..end]) |byte| {
            if (byte != '-') {
                return null;
            }
        }

        table.alignments[table.columns] = if (right) (if (left) .center else .right) else .left;
        table.columns += 1;
    }

    cells = Cells.init(header);
    var count: usize = 0;
    while (cells.next() != null) {
        count += 1;
        if (count > table.columns) {
            return null;
        }
    }

    if (count != table.columns) {
        return null;
    }

    const body_start = lines.index;
    table.len = body_start;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t");
        if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null or startsBlock(trimmed)) {
            break;
        }

        table.len = lines.index;
    }

    table.body = text[body_start..table.len];
    return table;
}

fn startsBlock(line: []const u8) bool {
    // A single physical line has no delimiter row, so table lookahead stops here.
    var blocks: Blocks = .{ .text = line };
    return (blocks.next() orelse return true).kind != .paragraph;
}

test "tables accept optional pipes CRLF alignments and ragged rows" {
    const source = "Name | Price | Note\r\n:--- | ---: | :---:\r\nA | 50 € | **yes**\r\nB | 60 €\r\n\r\nAfter";
    const table = Table.parse(source).?;
    try std.testing.expectEqual(@as(usize, 3), table.columns);
    try std.testing.expectEqualSlices(Alignment, &.{ .left, .right, .center }, table.alignments[0..3]);
    try std.testing.expectEqualStrings("A | 50 € | **yes**\r\nB | 60 €\r\n", table.body);
    try std.testing.expectEqualStrings("\r\nAfter", source[table.len..]);
}

test "tables reject malformed delimiters mismatched columns and excessive columns" {
    for ([_][]const u8{ "A | B\n--- | --\n", "A | B\n---\n", "A | B\n--- | --- | ---\n", "A | B\n--- | :\n", "plain\n---\n", "| a " ** 33 ++ "|\n" ++ "| --- " ** 33 ++ "|" }) |source| {
        try std.testing.expect(Table.parse(source) == null);
    }
}

test "table cell escapes preserve source slices and empty columns" {
    var cells = Cells.init("| a\\|b | `c\\|d` | \\ | | tail\\| ");
    for ([_][]const u8{ "a\\|b", "`c\\|d`", "\\", "", "tail\\|" }) |expected| {
        try std.testing.expectEqualStrings(expected, cells.next().?);
    }

    try std.testing.expect(cells.next() == null);
    cells = Cells.init("| a\\\\|b |");
    try std.testing.expectEqualStrings("a\\\\", cells.next().?);
    try std.testing.expectEqualStrings("b", cells.next().?);
}

test "tables stop before following blocks containing pipes without consuming them" {
    for ([_][]const u8{ "## Next | section", "12. First | item", "> Quote | text", "```text | info" }) |following| {
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "| A | B |\n| --- | --- |\n| x | y |\n{s}\n", .{following});
        const table = Table.parse(source).?;
        try std.testing.expectEqualStrings("| x | y |\n", table.body);
        try std.testing.expect(std.mem.startsWith(u8, source[table.len..], following));
    }

    try std.testing.expect(Table.parse("## Heading | Name\n--- | ---") == null);
}
