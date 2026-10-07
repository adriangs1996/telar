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
