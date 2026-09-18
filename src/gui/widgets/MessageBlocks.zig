//! A bounded Markdown block reader. Incomplete streaming fences remain code.
const std = @import("std");
const Block = @import("MessageBlock.zig");
const Blocks = @This();

text: []const u8,
markdown: bool = true,
index: usize = 0,

/// Reads headings, lists, quotes and fenced code without retaining source data.
/// Example: `while (blocks.next()) |block| try drawBlock(block);`
pub fn next(blocks: *Blocks) ?Block {
    if (blocks.index >= blocks.text.len) {
        return null;
    }

    const source_offset = blocks.index;
    const line = blocks.readLine();
    if (!blocks.markdown) {
        return .{ .text = line };
    }

    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) {
        return .{ .text = "", .kind = .spacer };
    }

    if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
        const fence = trimmed[0];
        var length: usize = 0;
        while (length < trimmed.len and trimmed[length] == fence) {
            length += 1;
        }

        const start = blocks.index;
        var end = start;
        var closed = false;
        while (blocks.index < blocks.text.len) {
            const before = blocks.index;
            const candidate = std.mem.trim(u8, blocks.readLine(), " \t");
            var count: usize = 0;
            while (count < candidate.len and candidate[count] == fence) {
                count += 1;
            }

            if (count >= length and std.mem.trim(u8, candidate[count..], " \t").len == 0) {
                end = before;
                closed = true;
                break;
            }

            end = blocks.index;
        }

        return .{ .text = std.mem.trimEnd(u8, blocks.text[start..end], "\r\n"), .kind = .code, .language = std.mem.trim(u8, trimmed[length..], " \t"), .fenced_closed = closed, .source_offset = @intCast(source_offset) };
    }

    if (std.mem.indexOfScalar(u8, line, '|') != null) {
        if (@import("MessageTable.zig").parse(blocks.text[source_offset..])) |table| {
            blocks.index = source_offset + table.len;
            return .{ .text = blocks.text[source_offset..blocks.index], .kind = .table, .source_offset = @intCast(source_offset) };
        }
    }

    var hashes: usize = 0;
    while (hashes < trimmed.len and trimmed[hashes] == '#') {
        hashes += 1;
    }

    if (hashes > 0 and hashes <= 6 and hashes < trimmed.len and trimmed[hashes] == ' ') {
        return .{ .text = std.mem.trim(u8, trimmed[hashes + 1 ..], " \t"), .kind = .heading };
    }

    if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***") or std.mem.eql(u8, trimmed, "___")) {
        return .{ .text = "", .kind = .rule };
    }

    if (trimmed.len >= 2 and trimmed[1] == ' ' and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+')) {
        return .{ .text = trimmed[2..], .kind = .bullet, .marker = "\u{2022}" };
    }

    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) {
        digits += 1;
    }

    if (digits > 0 and digits < 10 and digits + 1 < trimmed.len and (trimmed[digits] == '.' or trimmed[digits] == ')') and trimmed[digits + 1] == ' ') {
        return .{ .text = trimmed[digits + 2 ..], .kind = .bullet, .marker = trimmed[0 .. digits + 1] };
    }

    if (trimmed[0] == '>') {
        return .{ .text = std.mem.trimStart(u8, trimmed[1..], " \t"), .kind = .quote };
    }

    return .{ .text = line };
}

fn readLine(blocks: *Blocks) []const u8 {
    const start = blocks.index;
    while (blocks.index < blocks.text.len and blocks.text[blocks.index] != '\n' and blocks.text[blocks.index] != '\r') {
        blocks.index += 1;
    }

    const end = blocks.index;
    if (blocks.index < blocks.text.len) {
        const byte = blocks.text[blocks.index];
        blocks.index += 1;
        if (byte == '\r' and blocks.index < blocks.text.len and blocks.text[blocks.index] == '\n') {
            blocks.index += 1;
        }
    }

    return blocks.text[start..end];
}

test "message blocks preserve fenced output and recognize structure before wrapping" {
    var blocks: Blocks = .{ .text = "## Result\r\n\n- First\n12. Second\n> Note\n```zig\nconst x = 1;\n```\nDone" };
    try std.testing.expectEqual(.heading, blocks.next().?.kind);
    try std.testing.expectEqual(.spacer, blocks.next().?.kind);
    try std.testing.expectEqualStrings("\u{2022}", blocks.next().?.marker);
    try std.testing.expectEqualStrings("12.", blocks.next().?.marker);
    try std.testing.expectEqual(.quote, blocks.next().?.kind);
    const code = blocks.next().?;
    try std.testing.expectEqualStrings("zig", code.language);
    try std.testing.expectEqualStrings("const x = 1;", code.text);
    try std.testing.expectEqualStrings("Done", blocks.next().?.text);
    try std.testing.expect(blocks.next() == null);
}

test "streaming fences and literal user messages do not lose trailing bytes" {
    var blocks: Blocks = .{ .text = "~~~~python\nx = `value`\n~~~\n" };
    try std.testing.expectEqualStrings("x = `value`\n~~~", blocks.next().?.text);
    var literal: Blocks = .{ .text = "## Literal\n```\nx", .markdown = false };
    try std.testing.expectEqualStrings("## Literal", literal.next().?.text);
    try std.testing.expectEqualStrings("```", literal.next().?.text);
    try std.testing.expectEqualStrings("x", literal.next().?.text);
}

test "Mermaid fences become renderable only after an exact-language complete closing fence" {
    const source = "```mermaid\nflowchart TD\nA --> B\n```";
    for (1..source.len) |end| {
        var partial: Blocks = .{ .text = source[0..end] };
        try std.testing.expect(!partial.next().?.isMermaid());
    }

    var complete: Blocks = .{ .text = source };
    try std.testing.expect(complete.next().?.isMermaid());
    for ([_][]const u8{ "```Mermaid\nA-->B\n```", "```mermaid-extra\nA-->B\n```", "```mermaid title\nA-->B\n```", "````mermaid\nA-->B\n```", "```mermaid\nA-->B\n~~~" }) |invalid| {
        var blocks: Blocks = .{ .text = invalid };
        try std.testing.expect(!blocks.next().?.isMermaid());
    }
}

test "closed Mermaid fences retain distinct source offsets and CRLF bodies" {
    const prefix = "Intro\r\n";
    const first = "~~~mermaid\r\nflowchart TD\r\nA-->B\r\n~~~~\r\n";
    var blocks: Blocks = .{ .text = prefix ++ first ++ "```mermaid\nA-->B\n```" };
    _ = blocks.next();
    const left = blocks.next().?;
    try std.testing.expect(left.isMermaid());
    try std.testing.expectEqual(@as(u32, prefix.len), left.source_offset);
    try std.testing.expectEqualStrings("flowchart TD\r\nA-->B", left.text);
    const right = blocks.next().?;
    try std.testing.expect(right.isMermaid());
    try std.testing.expectEqual(@as(u32, prefix.len + first.len), right.source_offset);
    try std.testing.expectEqualStrings("A-->B", right.text);
}

test "tables become structured only after a matching delimiter and never inside code" {
    const source = "| Name | Price |\n| :--- | ---: |\n| Visit | 50 € |\n\nAfter";
    const complete = std.mem.indexOf(u8, source, "---:").? + 3;
    for (1..complete) |end| {
        var blocks: Blocks = .{ .text = source[0..end] };
        try std.testing.expect(blocks.next().?.kind != .table);
    }

    var blocks: Blocks = .{ .text = source };
    try std.testing.expectEqual(.table, blocks.next().?.kind);
    try std.testing.expectEqual(.spacer, blocks.next().?.kind);
    try std.testing.expectEqualStrings("After", blocks.next().?.text);
    blocks = .{ .text = "```md\n" ++ source ++ "\n```" };
    try std.testing.expectEqual(.code, blocks.next().?.kind);
    blocks = .{ .text = source, .markdown = false };
    try std.testing.expectEqual(.paragraph, blocks.next().?.kind);
}
