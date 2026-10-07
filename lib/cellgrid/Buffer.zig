const Cell = @import("Cell.zig");
const std = @import("std");
const Rect = @import("Rect.zig");
const Style = @import("Style.zig");
const Point = @import("Point.zig");
const GraphemeIterator = @import("GraphemeIterator.zig");
const Buffer = @This();

pub const Fill = @import("Fill.zig");

pub const CellWrite = @import("CellWrite.zig");

pub const TextWrite = @import("TextWrite.zig");

pub const Box = @import("Box.zig");

cells: []Cell,
w: u16,
h: u16,
gpa: std.mem.Allocator,

/// Nothing is written outside this. Starts as the whole buffer.
clip: Rect,
// SAFETY: pushClip writes each saved rectangle before increasing depth; popClip refuses an empty stack.
stack: [max_clip_depth]Rect = undefined,
depth: u8 = 0,

/// Base, a pane, a dropdown, a modal, a tooltip inside it. More nesting
/// than this is a layout that has lost track of itself.
pub const max_clip_depth = 8;

pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Buffer {
    const cells = try gpa.alloc(Cell, @as(usize, w) * @as(usize, h));
    @memset(cells, .{});
    return .{
        .cells = cells,
        .w = w,
        .h = h,
        .gpa = gpa,
        .clip = .{ .w = w, .h = h },
    };
}

pub fn deinit(self: *Buffer) void {
    self.gpa.free(self.cells);
}

pub fn resize(self: *Buffer, w: u16, h: u16) !void {
    // Fresh allocation rather than realloc: the old cells are cleared
    // below anyway, so copying them into the new block is wasted work.
    const cells = try self.gpa.alloc(Cell, @as(usize, w) * @as(usize, h));
    self.gpa.free(self.cells);
    self.cells = cells;
    self.w = w;
    self.h = h;
    // The clip described a buffer that no longer exists, and a stale one
    // would silently drop everything drawn outside the old bounds.
    self.clip = .{ .w = w, .h = h };
    self.depth = 0;
    @memset(self.cells, .{});
}

pub fn area(self: *const Buffer) Rect {
    return .{ .w = self.w, .h = self.h };
}

pub fn at(self: *Buffer, x: u16, y: u16) ?*Cell {
    if (x >= self.w or y >= self.h) {
        return null;
    }
    return &self.cells[@as(usize, y) * @as(usize, self.w) + @as(usize, x)];
}

pub fn clear(self: *Buffer, style: Style) void {
    @memset(self.cells, .{ .style = style });
}

pub fn fill(self: *Buffer, r: Rect, fill_value: Fill) void {
    // Edge sums in u32: `x + w` may exceed maxInt(u16), and positions past
    // it are unaddressable anyway.
    const x_end = @min(@as(u32, r.x) + r.w, @as(u32, std.math.maxInt(u16)) + 1);
    const y_end = @min(@as(u32, r.y) + r.h, @as(u32, std.math.maxInt(u16)) + 1);
    var y: u32 = r.y;
    while (y < y_end) : (y += 1) {
        var x: u32 = r.x;
        while (x < x_end) : (x += 1) {
            self.setCell(.{ .x = @intCast(x), .y = @intCast(y) }, .{ .text = fill_value.glyph, .width = 1, .style = fill_value.style });
        }
    }
}

/// Writes one grapheme cluster at an absolute position, unclipped.
///
/// Public because `blit` writes cells the emulator already laid out: it
/// knows each cluster's width from the pane's own tables and must not have
/// them measured a second time.
///
/// ```zig
/// buffer.setCell(.{ .x = 4, .y = 2 }, .{ .text = "界", .width = 2 });
/// ```
pub fn setCell(self: *Buffer, point: Point, value: CellWrite) void {
    if (!self.clip.contains(point.x, point.y)) {
        return;
    }

    // A wide glyph occupies the next column whether or not that column is
    // ours to write. Drawing the head alone makes the terminal advance two
    // columns and paint over the neighbour, so the glyph is replaced by a
    // blank that stays inside the clip.
    const fits = value.width != 2 or
        (point.x < std.math.maxInt(u16) and self.clip.contains(point.x + 1, point.y));
    const text = if (fits) value.text else " ";
    const drawn: u8 = if (fits) value.width else 1;

    const cell = self.at(point.x, point.y) orelse return;
    var len: u8 = @intCast(@min(text.len, Cell.max_bytes));
    // A cluster longer than the cell is cut, but never mid-codepoint:
    // invalid UTF-8 stored here would reach the host terminal verbatim.
    if (len < text.len) {
        while (len > 0 and text[len] & 0xc0 == 0x80) len -= 1;
    }
    cell.* = .{ .len = len, .width = drawn, .style = value.style };
    @memcpy(cell.bytes[0..len], text[0..len]);

    // The second column of a wide glyph. Width 0 keeps the diff from
    // emitting anything there and keeps a later write from leaving half of
    // a character behind.
    if (drawn == 2) {
        if (self.at(point.x + 1, point.y)) |tail| {
            tail.* = .{ .len = 0, .width = 0, .style = value.style };
        }
    }
}

/// Draws `text` at (x, y), clipped to `r`. Returns the columns advanced.
///
/// Iteration is by grapheme cluster, and the width comes from the same
/// table the build bound to `unicode`, which by default is the one laying
/// out the agents' own output. Anything else - counting bytes, counting
/// codepoints, guessing at emoji - drifts from what the terminal actually
/// does, and a UI whose idea of a column disagrees with the terminal's
/// smears on the first accented character.
///
/// ```zig
/// const width = buffer.writeText(area, .{ .point = .{ .x = 2, .y = 1 }, .text = "ready" });
/// ```
pub fn writeText(self: *Buffer, r: Rect, write: TextWrite) u16 {
    if (write.point.y < r.y or write.point.y >= @as(u32, r.y) + r.h) {
        return 0;
    }

    var column: u32 = write.point.x;
    const limit = @min(@as(u32, r.x) + r.w, @as(u32, std.math.maxInt(u16)) + 1);
    var it: GraphemeIterator = .{ .bytes = write.text };

    while (it.next()) |cluster| {
        if (column >= limit) {
            break;
        }
        // A wide glyph that would straddle the edge is dropped rather than
        // cut in half.
        if (cluster.width == 2 and column + 1 >= limit) {
            break;
        }
        if (column >= r.x) {
            self.setCell(.{ .x = @intCast(column), .y = write.point.y }, .{ .text = cluster.bytes, .width = cluster.width, .style = write.style });
        }
        column += cluster.width;
    }
    return @intCast(@min(column - write.point.x, std.math.maxInt(u16)));
}

/// Draws a box, with an optional title in the top edge.
///
/// ```zig
/// buffer.box(area, .{ .style = border, .title = " session " });
/// ```
pub fn box(self: *Buffer, r: Rect, box_value: Box) void {
    if (r.w < 2 or r.h < 2) {
        return;
    }
    // A box whose far edge leaves the addressable plane cannot be drawn
    // whole, and a partial box misleads more than no box.
    if (@as(u32, r.x) + r.w - 1 > std.math.maxInt(u16) or
        @as(u32, r.y) + r.h - 1 > std.math.maxInt(u16))
    {
        return;
    }
    const right = r.x + r.w - 1;
    const bottom = r.y + r.h - 1;

    var x = r.x + 1;
    while (x < right) : (x += 1) {
        self.setCell(.{ .x = x, .y = r.y }, .{ .text = "─", .width = 1, .style = box_value.style });
        self.setCell(.{ .x = x, .y = bottom }, .{ .text = "─", .width = 1, .style = box_value.style });
    }
    var y = r.y + 1;
    while (y < bottom) : (y += 1) {
        self.setCell(.{ .x = r.x, .y = y }, .{ .text = "│", .width = 1, .style = box_value.style });
        self.setCell(.{ .x = right, .y = y }, .{ .text = "│", .width = 1, .style = box_value.style });
    }
    self.setCell(.{ .x = r.x, .y = r.y }, .{ .text = "╭", .width = 1, .style = box_value.style });
    self.setCell(.{ .x = right, .y = r.y }, .{ .text = "╮", .width = 1, .style = box_value.style });
    self.setCell(.{ .x = r.x, .y = bottom }, .{ .text = "╰", .width = 1, .style = box_value.style });
    self.setCell(.{ .x = right, .y = bottom }, .{ .text = "╯", .width = 1, .style = box_value.style });

    if (box_value.title) |title| {
        const inside: Rect = .{ .x = r.x + 2, .y = r.y, .w = r.w -| 4, .h = 1 };
        _ = self.writeText(inside, .{ .point = .{ .x = r.x + 2, .y = r.y }, .text = title, .style = box_value.style });
    }
}
