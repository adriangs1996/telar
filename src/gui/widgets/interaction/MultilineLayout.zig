//! Wrapping shared by multiline editor drawing, pointer selection and native IME.
const cellgrid = @import("cellgrid");
const WrappedLines = @import("EditorLines.zig");
const Layout = @This();

text: []const u8,
head: u32,
columns: u16,
rows: u32,

/// Returns the first visible row while keeping the caret inside the editor.
/// Example: `const first = layout.firstRow();`
pub fn firstRow(self: Layout) u32 {
    return self.position(self.head)[1] -| (self.rows -| 1);
}

/// Measures a byte offset in wrapped columns and rows without allocating.
/// Example: `const caret = layout.position(field.head);`
pub fn position(self: Layout, at: u32) [2]u32 {
    var lines: WrappedLines = .{ .text = self.text, .width = self.columns };
    var row: u32 = 0;
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(self.text.ptr);
        const end = start + line.len;
        if (at < end or (at == end and (lines.finished or end < self.text.len and (self.text[end] == '\n' or self.text[end] == '\r')))) {
            const column = lines.position(at -| start);
            return .{ column, row };
        }

        row += 1;
    }

    return .{ 0, row -| 1 };
}

/// Maps a pointer in measured units to a complete grapheme in the visible rows.
/// Example: `const offset = layout.offset(.{ column, row });`
pub fn offset(self: Layout, point: [2]f64) u32 {
    const wanted = self.firstRow() + @as(u32, @intFromFloat(@max(0, @min(65535, @floor(point[1])))));
    var lines: WrappedLines = .{ .text = self.text, .width = self.columns };
    var row: u32 = 0;
    while (lines.next()) |line| {
        if (row != wanted) {
            row += 1;
            continue;
        }

        const start: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(self.text.ptr));
        var at = start;
        var used: f64 = @floatFromInt(lines.position(0));
        var nearest = @abs(point[0] - used);
        var iterator: cellgrid.GraphemeIterator = .{ .bytes = line };
        while (iterator.next()) |cluster| {
            used += @as(f64, @floatFromInt(cluster.width));
            const distance = @abs(point[0] - used);
            if (distance <= nearest) {
                nearest = distance;
                at = start + @as(u32, @intCast(iterator.index));
            }
        }

        return at;
    }

    return @intCast(self.text.len);
}

test "wrapped caret and pointer agree at UTF8 and newline boundaries" {
    const std = @import("std");
    const layout: Layout = .{ .text = "ab界c\nlast", .head = 6, .columns = 4, .rows = 2 };
    try std.testing.expectEqualDeep([2]u32{ 1, 1 }, layout.position(6));
    try std.testing.expectEqualDeep([2]u32{ 0, 2 }, layout.position(7));
    try std.testing.expectEqual(@as(u32, 2), layout.offset(.{ 2.1, 0 }));
    try std.testing.expectEqual(@as(u32, 5), layout.offset(.{ 0, 1 }));
    const scrolled: Layout = .{ .text = "one\ntwo\nthree", .head = 13, .columns = 8, .rows = 2 };
    try std.testing.expectEqual(@as(u32, 1), scrolled.firstRow());
    try std.testing.expectEqual(@as(u32, 4), scrolled.offset(.{ 0, 0 }));
}

test "a full last line keeps its caret visible and distinct from the next hard line" {
    const std = @import("std");
    const last: Layout = .{ .text = "abcd", .head = 4, .columns = 4, .rows = 1 };
    try std.testing.expectEqualDeep([2]u32{ 4, 0 }, last.position(4));
    try std.testing.expectEqual(@as(u32, 0), last.firstRow());
    const newline: Layout = .{ .text = "abcd\nef", .head = 0, .columns = 4, .rows = 2 };
    try std.testing.expectEqualDeep([2]u32{ 4, 0 }, newline.position(4));
    try std.testing.expectEqualDeep([2]u32{ 0, 1 }, newline.position(5));
    try std.testing.expectEqual(@as(u32, 4), newline.offset(.{ 4, 0 }));
    try std.testing.expectEqual(@as(u32, 5), newline.offset(.{ 0, 1 }));
}
