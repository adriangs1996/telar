//! Adapts a pane's cell row to core's byte-oriented link recognizer.

const max_uri_bytes_module = @import("telar-core").max_uri_bytes;
const CellType = @import("telar-core").Cell;
const BufferType = @import("telar-core").Buffer;
const ScrollType = @import("telar-core").Scroll;
const Position = @import("Position.zig");
const TargetType = @import("LinkTarget.zig");
const LinkMatch = @import("LinkMatch.zig");
const extractAt_module = @import("telar-core").extractAt;
const std = @import("std");

const row_window_bytes = max_uri_bytes_module * 2 + CellType.max_bytes * 2;

/// Extracts the textual URI under one absolute pane position without allocating.
///
/// ```zig
/// const target = extract(&buffer, scroll, .{ .x = 3, .y = 10 });
/// ```
pub fn extract(buffer: *const BufferType, scroll: ScrollType, position: Position) ?TargetType {
    const found = match(buffer, scroll, position) orelse return null;
    return found.target;
}

/// Resolves a URI and its exclusive cell interval in absolute pane coordinates.
/// The row window and the owned target are bounded; no allocation occurs.
/// Example: `const found = match(&buffer, scroll, .{ .x = 3, .y = 10 });`
pub fn match(buffer: *const BufferType, scroll: ScrollType, position: Position) ?LinkMatch {
    if (position.x >= buffer.w or position.y < scroll.offset) {
        return null;
    }

    const relative_y = position.y - scroll.offset;
    if (relative_y >= buffer.h) {
        return null;
    }

    const row_start = @as(usize, @intCast(relative_y)) * buffer.w;
    const row = buffer.cells[row_start..][0..buffer.w];
    var cursor_x = position.x;
    if (row[cursor_x].width == 0) {
        if (cursor_x == 0 or row[cursor_x - 1].width != 2) {
            return null;
        }

        cursor_x -= 1;
    }

    var start_x = cursor_x;
    var bytes_before: usize = 0;
    while (start_x != 0 and bytes_before <= max_uri_bytes_module) {
        start_x -= 1;
        bytes_before += row[start_x].text().len;
    }

    var storage: [row_window_bytes]u8 = undefined;
    var len: usize = 0;
    var cursor_offset: ?usize = null;
    var x = start_x;
    while (x < buffer.w) : (x += 1) {
        if (x == cursor_x) {
            cursor_offset = len;
        }

        const text = row[x].text();
        if (text.len > storage.len - len) {
            break;
        }

        @memcpy(storage[len .. len + text.len], text);
        len += text.len;

        if (cursor_offset) |offset| {
            if (len - offset >= max_uri_bytes_module + CellType.max_bytes) {
                break;
            }
        }
    }

    const offset = cursor_offset orelse return null;
    const found = extractAt_module(storage[0..len], offset) orelse return null;
    const range = columns(row, start_x, .{ found.start, found.end }) orelse return null;
    return .{
        .target = TargetType.init(found.text(storage[0..len])) catch return null,
        .start = .{ .x = range[0], .y = position.y },
        .end = .{ .x = range[1], .y = position.y },
    };
}

fn columns(row: []const CellType, start_x: u16, span: [2]usize) ?[2]u16 {
    var offset: usize = 0;
    var start: ?u16 = null;
    for (row[start_x..], start_x..) |cell, x| {
        const end = offset + cell.text().len;
        if (start == null and offset <= span[0] and end > span[0]) {
            start = @intCast(x);
        }

        if (end >= span[1]) {
            return .{ start orelse return null, @intCast(@min(row.len, x + @max(1, cell.width))) };
        }

        offset = end;
    }

    return null;
}

fn testBuffer(rows: []const []const u8) !BufferType {
    var width: u16 = 0;
    for (rows) |row| {
        width = @max(width, @as(u16, @intCast(row.len)));
    }

    var buffer = try BufferType.init(std.testing.allocator, width, @intCast(rows.len));
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{} });
    for (rows, 0..) |row, y| {
        _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = @intCast(y) }, .text = row, .style = .{} });
    }

    return buffer;
}

test "cell extraction maps an absolute copy cursor to core link bytes" {
    var buffer = try testBuffer(&.{ "plain", "open https://example.com/a now" });
    defer buffer.deinit();

    const target = extract(&buffer, .{ .total_rows = 12, .offset = 10 }, .{ .x = 15, .y = 11 }).?;

    try std.testing.expectEqualStrings("https://example.com/a", target.uri());
}

test "cell extraction rejects positions outside the retained frame" {
    var buffer = try testBuffer(&.{"https://example.com"});
    defer buffer.deinit();

    try std.testing.expect(extract(&buffer, .{ .total_rows = 11, .offset = 10 }, .{ .x = 2, .y = 9 }) == null);
    try std.testing.expect(extract(&buffer, .{ .total_rows = 11, .offset = 10 }, .{ .x = buffer.w, .y = 10 }) == null);
}

test "link intervals exclude prose punctuation and keep absolute pane rows" {
    var buffer = try testBuffer(&.{ "plain", "open (https://example.com/a_(b)), https://two.example." });
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 8002, .offset = 8000 };
    const uri = "https://example.com/a_(b)";
    for (6..6 + uri.len) |x| {
        const found = match(&buffer, scroll, .{ .x = @intCast(x), .y = 8001 }).?;
        try std.testing.expectEqualStrings(uri, found.target.uri());
        try std.testing.expectEqualDeep(Position{ .x = 6, .y = 8001 }, found.start);
        try std.testing.expectEqualDeep(Position{ .x = 6 + uri.len, .y = 8001 }, found.end);
    }

    try std.testing.expect(match(&buffer, scroll, .{ .x = 5, .y = 8001 }) == null);
    try std.testing.expect(match(&buffer, scroll, .{ .x = 6 + uri.len, .y = 8001 }) == null);
    const second = match(&buffer, scroll, .{ .x = 36, .y = 8001 }).?;
    try std.testing.expectEqualStrings("https://two.example", second.target.uri());
}

test "Unicode link intervals use columns rather than bytes or codepoints" {
    var buffer = try testBuffer(&.{"界e\u{301} https://e/路e\u{301}."});
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 41, .offset = 40 };
    for (4..17) |x| {
        const found = match(&buffer, scroll, .{ .x = @intCast(x), .y = 40 }).?;
        try std.testing.expectEqualStrings("https://e/路e\u{301}", found.target.uri());
        try std.testing.expectEqualDeep(Position{ .x = 4, .y = 40 }, found.start);
        try std.testing.expectEqualDeep(Position{ .x = 17, .y = 40 }, found.end);
    }

    try std.testing.expect(match(&buffer, scroll, .{ .x = 3, .y = 40 }) == null);
    try std.testing.expect(match(&buffer, scroll, .{ .x = 17, .y = 40 }) == null);
}

test "both halves of a final wide URI glyph extract the same target" {
    var buffer = try BufferType.init(std.testing.allocator, 12, 1);
    defer buffer.deinit();
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://e/界", .style = .{} });
    const scroll: ScrollType = .{ .total_rows = 1, .offset = 0 };
    try std.testing.expectEqual(@as(u8, 0), buffer.cells[11].width);
    const head = extract(&buffer, scroll, .{ .x = 10, .y = 0 }).?;
    const tail = extract(&buffer, scroll, .{ .x = 11, .y = 0 }) orelse return error.MissingWideContinuationLink;
    try std.testing.expect(head.eql(&tail));
    try std.testing.expectEqualStrings("https://e/界", tail.uri());
    const found = match(&buffer, scroll, .{ .x = 11, .y = 0 }).?;
    try std.testing.expectEqual(@as(u16, 0), found.start.x);
    try std.testing.expectEqual(@as(u16, 12), found.end.x);
}

test "matched targets own their bytes and reject out-of-viewport positions" {
    var buffer = try testBuffer(&.{"file:///tmp/a%20b.txt"});
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = std.math.maxInt(u32), .offset = std.math.maxInt(u32) - 1 };
    const found = match(&buffer, scroll, .{ .x = 7, .y = scroll.offset }).?;
    try std.testing.expectEqual(scroll.offset, found.start.y);
    try std.testing.expectEqual(scroll.offset, found.end.y);
    try std.testing.expectEqual(@as(u16, 21), found.end.x);
    try std.testing.expect(match(&buffer, scroll, .{ .x = buffer.w, .y = scroll.offset }) == null);
    try std.testing.expect(match(&buffer, scroll, .{ .x = 2, .y = scroll.offset - 1 }) == null);
    try std.testing.expect(match(&buffer, scroll, .{ .x = 2, .y = scroll.offset + 1 }) == null);
    buffer.clear(.{});
    try std.testing.expectEqualStrings("file:///tmp/a%20b.txt", found.target.uri());
    try std.testing.expect(match(&buffer, scroll, .{ .x = 7, .y = scroll.offset }) == null);
}

test "maximum URI length remains bounded inside a larger row window" {
    const uri = "https://e/" ++ "a" ** (max_uri_bytes_module - "https://e/".len);
    var buffer = try testBuffer(&.{"prefix " ++ uri ++ " suffix https://other.example"});
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 1, .offset = 0 };
    for ([_]u16{ 7, 7 + max_uri_bytes_module / 2, 7 + max_uri_bytes_module - 1 }) |x| {
        const found = match(&buffer, scroll, .{ .x = x, .y = 0 }).?;
        try std.testing.expectEqualStrings(uri, found.target.uri());
        try std.testing.expectEqual(@as(u16, 7), found.start.x);
        try std.testing.expectEqual(@as(u16, 7 + max_uri_bytes_module), found.end.x);
        const target = extract(&buffer, scroll, .{ .x = x, .y = 0 }).?;
        try std.testing.expect(found.target.eql(&target));
    }

    try std.testing.expect(match(&buffer, scroll, .{ .x = 7 + max_uri_bytes_module, .y = 0 }) == null);
    const other = match(&buffer, scroll, .{ .x = 7 + max_uri_bytes_module + 12, .y = 0 }).?;
    try std.testing.expectEqualStrings("https://other.example", other.target.uri());
}

test "matching retains supported schemes and does not join physical rows" {
    var buffer = try testBuffer(&.{ "https://example", ".com/path", "javascript:alert(1)", "data:text/plain,hi", "./src/main.zig" });
    defer buffer.deinit();
    const scroll: ScrollType = .{ .total_rows = 5, .offset = 0 };
    const found = match(&buffer, scroll, .{ .x = 8, .y = 0 }).?;
    try std.testing.expectEqualStrings("https://example", found.target.uri());
    for (1..5) |y| {
        try std.testing.expect(match(&buffer, scroll, .{ .x = 3, .y = @intCast(y) }) == null);
    }
}
