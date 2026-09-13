//! Disjoint rectangles for box strokes, so faint intersections blend only once.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Grid = @import("BoxGrid.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("TextRun.zig");
const Ink = @This();

pub const capacity = 21;
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

fn append(ink: *Ink, rect: Rect) !void {
    for (ink.rects[0..ink.count]) |*previous| {
        if (previous.x == rect.x and previous.width == rect.width and previous.y + previous.height == rect.y) {
            previous.height += rect.height;
            return;
        }
    }

    if (ink.count == capacity) {
        return error.BoxQuadBudgetExceeded;
    }

    ink.rects[ink.count] = rect;
    ink.count += 1;
}

/// Uses local cell coordinates; Unicode weight wins over bold/italic font flags.
/// Example: `try ink.paint(run, list);`
pub fn paint(ink: *const Ink, run: TextRun, list: *QuadList) !void {
    const bounds = run.cell_bounds orelse return error.MissingCellBounds;
    for (ink.rects[0..ink.count]) |rect| {
        var placed = rect;
        placed.x += run.x + bounds.x;
        placed.y += run.y + bounds.y;
        try list.pushRect(placed, run.color);
    }
}

test "all box intersections and dash patterns remain disjoint and within the mesh budget" {
    const widths = [_]f32{ 0, 0.25, 0.5, 1, 2, 3, 5, 9, 11, 16, 26, 70.25 };
    const heights = [_]f32{ 0, 0.5, 1, 3, 5, 8, 17, 21, 32, 71, 94.75 };
    for (widths) |width| {
        for (heights) |height| {
            for ([_]f32{ 1, 2, 3, 5 }) |thickness| {
                for (0x2500..0x2580) |cp| {
                    const box: @import("BoxDrawing.zig") = .{ .codepoint = @intCast(cp) };
                    if (box.curve() != null) {
                        continue;
                    }

                    var grid = try Grid.init(.{ .x = 0, .y = 0, .width = width, .height = height }, thickness);
                    grid.draw(box);
                    const ink = try init(&grid);
                    try std.testing.expect(ink.count <= capacity);
                    const rects = ink.rects[0..ink.count];
                    for (rects, 0..) |a, i| {
                        try std.testing.expect(a.x >= 0 and a.y >= 0 and a.width > 0 and a.height > 0);
                        try std.testing.expect(a.x + a.width <= width and a.y + a.height <= height);
                        for (rects[i + 1 ..]) |b| {
                            const overlap = @min(a.x + a.width, b.x + b.width) > @max(a.x, b.x) and
                                @min(a.y + a.height, b.y + b.height) > @max(a.y, b.y);
                            try std.testing.expect(!overlap);
                        }
                    }
                }
            }
        }
    }
}

test "union preserves the exact stroke coverage and Unicode double center gap" {
    for (0x2500..0x2580) |cp| {
        const box: @import("BoxDrawing.zig") = .{ .codepoint = @intCast(cp) };
        if (box.curve() != null) {
            continue;
        }

        var grid = try Grid.init(.{ .x = 0, .y = 0, .width = 11, .height = 21 }, 2);
        grid.draw(box);
        const ink = try init(&grid);
        for (0..21) |y| {
            for (0..11) |x| {
                const point = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                try std.testing.expectEqual(contains(grid.rects[0..grid.count], point), contains(ink.rects[0..ink.count], point));
            }
        }
    }

    var cross = try Grid.init(.{ .x = 0, .y = 0, .width = 11, .height = 21 }, 1);
    cross.draw(.{ .codepoint = 0x256c });
    const ink = try init(&cross);
    try std.testing.expect(!contains(ink.rects[0..ink.count], .{ 5.5, 10.5 }));
    try std.testing.expect(contains(ink.rects[0..ink.count], .{ 4.5, 9.5 }));
    try std.testing.expect(contains(ink.rects[0..ink.count], .{ 6.5, 11.5 }));
}

fn contains(rects: []const Rect, point: [2]f32) bool {
    for (rects) |rect| {
        if (point[0] >= rect.x and point[0] < rect.x + rect.width and point[1] >= rect.y and point[1] < rect.y + rect.height) {
            return true;
        }
    }

    return false;
}
