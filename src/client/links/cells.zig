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
const max_walk_cells = row_window_bytes * 2;

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
    return matchGrid(.{ .buffer = buffer, .scroll = scroll }, position);
}

/// Resolves OSC 8 first, then visible URI text across VT-confirmed soft wraps.
/// Example: `const found = resolve(pane, .{ .x = 3, .y = pane.scroll.offset });`
pub fn resolve(pane: *const @import("../panes/Pane.zig"), position: Position) ?LinkMatch {
    const metadata = pane.text_metadata.view();
    const grid: @import("LinkGrid.zig") = .{ .buffer = &pane.buffer, .scroll = pane.scroll, .rows = metadata.rows };
    const index = grid.cellIndex(position) orelse return null;
    if (metadata.at(@intCast(index))) |run| {
        return .{
            .target = TargetType.init(metadata.link(run.link_index).?) catch return null,
            .start = grid.position(run.start),
            .end = grid.cellEnd(run.start + run.len - 1),
            .link_index = run.link_index,
        };
    }

    // A discarded link table cannot authorize a label as its own destination.
    if (metadata.status == .omitted and metadata.rows[index / pane.buffer.w].hyperlinks) {
        return null;
    }

    return matchGrid(grid, position);
}

fn matchGrid(grid: @import("LinkGrid.zig"), position: Position) ?LinkMatch {
    const cursor = grid.cellIndex(position) orelse return null;
    var start = cursor;
    var bytes_before: usize = 0;
    var visited: usize = 0;
    while (bytes_before <= max_uri_bytes_module) {
        if (visited == max_walk_cells) {
            return null;
        }

        visited += 1;
        start = grid.previous(start) orelse break;
        bytes_before += grid.buffer.cells[start].text().len;
    }

    var storage: [row_window_bytes]u8 = undefined;
    var len: usize = 0;
    var cursor_offset: ?usize = null;
    var index = start;
    visited = 0;
    while (true) {
        if (visited == max_walk_cells) {
            return null;
        }

        visited += 1;
        if (index == cursor) {
            cursor_offset = len;
        }

        const text = grid.buffer.cells[index].text();
        if (text.len > storage.len - len) {
            break;
        }

        @memcpy(storage[len..][0..text.len], text);
        len += text.len;
        if (cursor_offset) |offset| {
            if (len - offset >= max_uri_bytes_module + CellType.max_bytes) {
                break;
            }
        }

        index = grid.next(index) orelse break;
    }

    const offset = cursor_offset orelse return null;
    const found = extractAt_module(storage[0..len], offset) orelse return null;
    const range = positions(grid, start, .{ found.start, found.end }) orelse return null;
    if (!completeRange(grid, range)) {
        return null;
    }

    return .{
        .target = TargetType.init(found.text(storage[0..len])) catch return null,
        .start = range[0],
        .end = range[1],
    };
}

fn completeRange(grid: @import("LinkGrid.zig"), range: [2]Position) bool {
    if (grid.rows.len == 0) {
        return true;
    }

    if (range[0].y == grid.scroll.offset and range[0].x == 0 and grid.rows[0].continuation) {
        return false;
    }

    const last = grid.rows[grid.rows.len - 1];
    const last_text_column = grid.buffer.w - @intFromBool(last.wide_padding);
    return !(range[1].y - grid.scroll.offset == grid.rows.len - 1 and range[1].x == last_text_column and last.wrap);
}

fn positions(grid: @import("LinkGrid.zig"), first: usize, span: [2]usize) ?[2]Position {
    var index = first;
    var offset: usize = 0;
    var start: ?Position = null;
    while (true) {
        const cell = &grid.buffer.cells[index];
        const end = offset + cell.text().len;
        if (start == null and offset <= span[0] and end > span[0]) {
            start = grid.position(index);
        }

        if (end >= span[1]) {
            return .{ start orelse return null, grid.cellEnd(index) };
        }

        offset = end;
        index = grid.next(index) orelse return null;
    }
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

fn testPane(size: [2]u16) !@import("../panes/Pane.zig") {
    var pane = try @import("../panes/Pane.zig").init(std.testing.allocator, .{
        .spec = .{
            .pane_id = @enumFromInt(1),
            .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
            .size = .{ .cols = size[0], .rows = size[1] },
        },
        .attached = true,
    });
    pane.buffer.clear(.{});
    return pane;
}

test "pane link resolution follows only soft wraps and skips wide padding" {
    const core = @import("telar-core");
    var pane = try testPane(.{ 12, 3 });
    defer pane.deinit();
    pane.scroll = .{ .offset = 90, .total_rows = 93 };
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://e/a", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "界z", .style = .{} });
    var storage: [core.text_metadata_limits.capacity(3)]u8 = undefined;
    var builder = core.TextMetadataBuilder.init(&storage, 3);
    builder.setRow(0, .{ .wrap = true, .wide_padding = true });
    builder.setRow(1, .{ .continuation = true });
    pane.text_metadata.replace(builder.finish(.complete));
    for ([_]Position{ .{ .x = 0, .y = 90 }, .{ .x = 10, .y = 90 }, .{ .x = 0, .y = 91 }, .{ .x = 1, .y = 91 }, .{ .x = 2, .y = 91 } }) |position| {
        const found = resolve(&pane, position).?;
        try std.testing.expectEqualStrings("https://e/a界z", found.target.uri());
        try std.testing.expectEqualDeep(Position{ .x = 0, .y = 90 }, found.start);
        try std.testing.expectEqualDeep(Position{ .x = 3, .y = 91 }, found.end);
        try std.testing.expectEqual(null, found.link_index);
    }

    try std.testing.expect(resolve(&pane, .{ .x = 11, .y = 90 }) == null);
    try std.testing.expect(resolve(&pane, .{ .x = 3, .y = 91 }) == null);
    builder = core.TextMetadataBuilder.init(&storage, 3);
    pane.text_metadata.replace(builder.finish(.complete));
    try std.testing.expect(resolve(&pane, .{ .x = 1, .y = 91 }) == null);
}

test "OSC 8 destinations win over labels and omitted tables never authorize labels" {
    const core = @import("telar-core");
    var pane = try testPane(.{ 24, 2 });
    defer pane.deinit();
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://label.example", .style = .{} });
    var storage: [core.text_metadata_limits.capacity(2)]u8 = undefined;
    var builder = core.TextMetadataBuilder.init(&storage, 2);
    builder.setRow(0, .{ .hyperlinks = true });
    const id = try builder.addLink("https://destination.example/path");
    try builder.addRun(.{ .start = 0, .len = 21, .link_index = id });
    try builder.addRun(.{ .start = 25, .len = 4, .link_index = id });
    pane.text_metadata.replace(builder.finish(.complete));
    const found = resolve(&pane, .{ .x = 9, .y = 0 }).?;
    try std.testing.expectEqualStrings("https://destination.example/path", found.target.uri());
    try std.testing.expectEqual(@as(?u16, 0), found.link_index);
    try std.testing.expectEqual(@as(u16, 21), found.end.x);
    const repeated = resolve(&pane, .{ .x = 2, .y = 1 }).?;
    try std.testing.expect(found.target.eql(&repeated.target));
    try std.testing.expectEqual(found.link_index, repeated.link_index);
    builder = core.TextMetadataBuilder.init(&storage, 2);
    builder.setRow(0, .{ .hyperlinks = true });
    const unsafe_id = try builder.addLink("javascript:alert(1)");
    try builder.addRun(.{ .start = 0, .len = 21, .link_index = unsafe_id });
    pane.text_metadata.replace(builder.finish(.complete));
    try std.testing.expect(resolve(&pane, .{ .x = 9, .y = 0 }) == null);
    builder = core.TextMetadataBuilder.init(&storage, 2);
    builder.setRow(0, .{ .hyperlinks = true });
    pane.text_metadata.replace(builder.finish(.omitted));
    try std.testing.expect(resolve(&pane, .{ .x = 9, .y = 0 }) == null);
    builder = core.TextMetadataBuilder.init(&storage, 2);
    pane.text_metadata.replace(builder.finish(.complete));
    try std.testing.expectEqualStrings("https://label.example", resolve(&pane, .{ .x = 9, .y = 0 }).?.target.uri());
}

test "link windows remain bounded by cells when grapheme bytes are empty" {
    var buffer = try BufferType.init(std.testing.allocator, max_walk_cells + 64, 1);
    defer buffer.deinit();
    @memset(buffer.cells, .{ .len = 0, .width = 1 });
    const x = max_walk_cells + 1;
    _ = buffer.writeText(buffer.area(), .{ .point = .{ .x = x, .y = 0 }, .text = "https://e", .style = .{} });
    try std.testing.expect(match(&buffer, .{ .total_rows = 1, .offset = 0 }, .{ .x = x, .y = 0 }) == null);
}

test "a soft wrapped URI clipped by the viewport is not opened as a truncated URI" {
    const core = @import("telar-core");
    var pane = try testPane(.{ 12, 1 });
    defer pane.deinit();
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://e/ab", .style = .{} });
    var storage: [core.text_metadata_limits.capacity(1)]u8 = undefined;
    var builder = core.TextMetadataBuilder.init(&storage, 1);
    builder.setRow(0, .{ .wrap = true });
    pane.text_metadata.replace(builder.finish(.complete));
    try std.testing.expect(resolve(&pane, .{ .x = 2, .y = 0 }) == null);
    builder = core.TextMetadataBuilder.init(&storage, 1);
    builder.setRow(0, .{ .continuation = true });
    pane.text_metadata.replace(builder.finish(.complete));
    try std.testing.expect(resolve(&pane, .{ .x = 2, .y = 0 }) == null);
}
