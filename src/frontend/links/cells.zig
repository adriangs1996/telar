//! Adapts a pane's cell row to core's byte-oriented link recognizer.

const std = @import("std");
const core = @import("telar-core");
const target_mod = @import("target.zig");

const link = core.link;
const schema = core.schema;
const ui = core.ui;

pub const Position = struct {
    x: u16,
    y: u32,
};

const row_window_bytes = link.max_uri_bytes * 2 + ui.Cell.max_bytes * 2;

/// Extracts the textual URI under one absolute pane position without allocating.
///
/// ```zig
/// const target = extract(&buffer, scroll, .{ .x = 3, .y = 10 });
/// ```
pub fn extract(buffer: *const ui.Buffer, scroll: schema.frame.Scroll, position: Position) ?target_mod.Target {
    if (position.x >= buffer.w or position.y < scroll.offset) {
        return null;
    }

    const relative_y = position.y - scroll.offset;
    if (relative_y >= buffer.h) {
        return null;
    }

    var start_x = position.x;
    var bytes_before: usize = 0;
    while (start_x != 0 and bytes_before <= link.max_uri_bytes) {
        start_x -= 1;
        bytes_before += cellAt(buffer, start_x, @intCast(relative_y)).text().len;
    }

    var storage: [row_window_bytes]u8 = undefined;
    var len: usize = 0;
    var cursor_offset: ?usize = null;
    var x = start_x;
    while (x < buffer.w) : (x += 1) {
        if (x == position.x) {
            cursor_offset = len;
        }

        const text = cellAt(buffer, x, @intCast(relative_y)).text();
        if (text.len > storage.len - len) {
            break;
        }

        @memcpy(storage[len .. len + text.len], text);
        len += text.len;

        if (cursor_offset) |offset| {
            if (len - offset >= link.max_uri_bytes + ui.Cell.max_bytes) {
                break;
            }
        }
    }

    const offset = cursor_offset orelse return null;
    const match = link.extractAt(storage[0..len], offset) orelse return null;

    return target_mod.Target.init(match.text(storage[0..len])) catch null;
}

fn cellAt(buffer: *const ui.Buffer, x: u16, y: u16) *const ui.Cell {
    return &buffer.cells[@as(usize, y) * buffer.w + x];
}

fn testBuffer(rows: []const []const u8) !ui.Buffer {
    var width: u16 = 0;
    for (rows) |row| {
        width = @max(width, @as(u16, @intCast(row.len)));
    }

    var buffer = try ui.Buffer.init(std.testing.allocator, width, @intCast(rows.len));
    buffer.fill(buffer.area(), " ", .{});
    for (rows, 0..) |row, y| {
        _ = buffer.writeText(buffer.area(), 0, @intCast(y), row, .{});
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
