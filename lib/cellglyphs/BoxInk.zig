//! Disjoint rectangles for box strokes, so faint intersections blend only once.
const std = @import("std");
const gfx = @import("gfx");
const Color = gfx.Color;
const QuadList = gfx.QuadList;
const Rect = gfx.Rect;
const Grid = @import("BoxGrid.zig");
const Ink = @This();

pub const capacity = 21;
// SAFETY: append writes a rectangle before increasing count; merging and paint inspect only the populated prefix.
rects: [capacity]Rect = undefined,
count: u5 = 0,

/// Unions at most eight axis-aligned strokes with a bounded scan over their edges.
/// Example: `const ink = try BoxInk.init(&grid);`
pub fn init(grid: *const Grid) !Ink {
    var ink: Ink = .{};
    var rows: [16]f32 = undefined;
    const strokes = grid.rects[0..grid.count];
    for (strokes, 0..) |rect, i| {
        rows[2 * i] = rect.y;
        rows[2 * i + 1] = rect.y + rect.height;
    }

    const edges = rows[0 .. 2 * strokes.len];
    std.mem.sort(f32, edges, {}, std.sort.asc(f32));
    if (edges.len == 0) {
        return ink;
    }

    for (edges[0 .. edges.len - 1], edges[1..]) |top, bottom| {
        if (top == bottom) {
            continue;
        }

        var intervals: [8][2]f32 = undefined;
        var length: usize = 0;
        for (strokes) |rect| {
            if (rect.y <= top and rect.y + rect.height >= bottom) {
                intervals[length] = .{ rect.x, rect.x + rect.width };
                length += 1;
            }
        }

        std.mem.sort([2]f32, intervals[0..length], {}, less);
        var index: usize = 0;
        while (index < length) {
            const left = intervals[index][0];
            var right = intervals[index][1];
            index += 1;
            while (index < length and intervals[index][0] <= right) : (index += 1) {
                right = @max(right, intervals[index][1]);
            }

            try ink.append(.{ .x = left, .y = top, .width = right - left, .height = bottom - top });
        }
    }

    return ink;
}

fn less(_: void, a: [2]f32, b: [2]f32) bool {
    return a[0] < b[0];
}

fn append(self: *Ink, rect: Rect) !void {
    for (self.rects[0..self.count]) |*previous| {
        if (previous.x == rect.x and previous.width == rect.width and previous.y + previous.height == rect.y) {
            previous.height += rect.height;
            return;
        }
    }

    if (self.count == capacity) {
        return error.BoxQuadBudgetExceeded;
    }

    self.rects[self.count] = rect;
    self.count += 1;
}

/// Places the strokes in `cell`, the cell's rectangle in device pixels;
/// Unicode weight wins over bold/italic font flags.
/// Example: `try ink.paint(cell, color, list);`
pub fn paint(self: *const Ink, cell: Rect, color: Color, list: *QuadList) !void {
    for (self.rects[0..self.count]) |rect| {
        var placed = rect;
        placed.x += cell.x;
        placed.y += cell.y;
        try list.pushRect(placed, color);
    }
}
