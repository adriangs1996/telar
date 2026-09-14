//! Solid rectangles for one block element, measured from the complete cell so
//! ink meets every cell edge regardless of line height or letter spacing.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Block = @import("BlockElement.zig");
const block_shapes = @import("block_shapes.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("TextRun.zig");
const Ink = @This();

pub const capacity = 2;
rects: [capacity]Rect = undefined,
count: u2 = 0,
/// Fraction of the run color's alpha the rectangles keep; shades blend evenly.
coverage: f32 = 1,

/// Splits cell extents at whole pixels so halves, eighths and quadrants tile.
/// Example: `const ink = try BlockInk.init(cell, block);`
pub fn init(cell: Rect, block: Block) !Ink {
    if (!std.math.isFinite(cell.x) or !std.math.isFinite(cell.y) or
        !std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or
        cell.width < 0 or cell.height < 0 or cell.width > 65535 or cell.height > 65535)
    {
        return error.InvalidCellBounds;
    }

    var ink: Ink = .{};
    switch (block_shapes.get(block.codepoint)) {
        .slab => |shape| ink.slab(cell, shape),
        .quadrants => |mask| ink.quadrants(cell, mask),
        .shade => |coverage| {
            ink.coverage = coverage;
            ink.append(.{ .x = 0, .y = 0, .width = cell.width, .height = cell.height });
        },
    }

    return ink;
}

/// Uses local cell coordinates; bold and italic do not deform the geometry.
/// Example: `try ink.paint(run, list);`
pub fn paint(ink: *const Ink, run: TextRun, list: *QuadList) !void {
    const bounds = run.cell_bounds orelse return error.MissingCellBounds;
    var color = run.color;
    color.a *= ink.coverage;
    for (ink.rects[0..ink.count]) |rect| {
        var placed = rect;
        placed.x += run.x + bounds.x;
        placed.y += run.y + bounds.y;
        try list.pushRect(placed, color);
    }
}

fn slab(ink: *Ink, cell: Rect, shape: @import("BlockSlab.zig")) void {
    switch (shape.side) {
        .top => ink.append(.{ .x = 0, .y = 0, .width = cell.width, .height = split(cell.height, shape.eighths) }),
        .bottom => {
            const top = split(cell.height, 8 - shape.eighths);
            ink.append(.{ .x = 0, .y = top, .width = cell.width, .height = cell.height - top });
        },
        .left => ink.append(.{ .x = 0, .y = 0, .width = split(cell.width, shape.eighths), .height = cell.height }),
        .right => {
            const left = split(cell.width, 8 - shape.eighths);
            ink.append(.{ .x = left, .y = 0, .width = cell.width - left, .height = cell.height });
        },
    }
}

fn quadrants(ink: *Ink, cell: Rect, mask: u4) void {
    const middle_x = split(cell.width, 4);
    const middle_y = split(cell.height, 4);
    const tops = [2]f32{ 0, middle_y };
    const bottoms = [2]f32{ middle_y, cell.height };
    for (tops, bottoms, 0..) |top, bottom, row| {
        const left = (mask >> @intCast(2 * row)) & 1 != 0;
        const right = (mask >> @intCast(2 * row + 1)) & 1 != 0;
        const x: f32 = if (left) 0 else middle_x;
        const right_edge: f32 = if (right) cell.width else middle_x;
        if (left or right) {
            ink.append(.{ .x = x, .y = top, .width = right_edge - x, .height = bottom - top });
        }
    }
}

// The pixel row or column `eighths` eighths from the cell origin, so slabs
// anchored to opposite edges share one boundary and tile exactly.
fn split(extent: f32, eighths: u4) f32 {
    if (eighths >= 8) {
        return extent;
    }

    return @round(extent * @as(f32, @floatFromInt(eighths)) / 8);
}

fn append(ink: *Ink, rect: Rect) void {
    if (rect.width <= 0 or rect.height <= 0) {
        return;
    }

    if (ink.count > 0) {
        const previous = &ink.rects[ink.count - 1];
        if (previous.x == rect.x and previous.width == rect.width and previous.y + previous.height == rect.y) {
            previous.height += rect.height;
            return;
        }
    }

    std.debug.assert(ink.count < capacity);
    ink.rects[ink.count] = rect;
    ink.count += 1;
}

fn covered(ink: *const Ink, point: [2]f32) bool {
    for (ink.rects[0..ink.count]) |rect| {
        if (point[0] >= rect.x and point[0] < rect.x + rect.width and point[1] >= rect.y and point[1] < rect.y + rect.height) {
            return true;
        }
    }

    return false;
}

fn area(ink: *const Ink) f32 {
    var total: f32 = 0;
    for (ink.rects[0..ink.count]) |rect| {
        total += rect.width * rect.height;
    }

    return total;
}

test "the full block covers the cell and every element stays inside it across cell sizes" {
    const widths = [_]f32{ 0, 0.25, 1, 2, 3, 7, 8, 9, 11, 16, 26, 70.25 };
    const heights = [_]f32{ 0, 0.5, 1, 3, 5, 8, 17, 21, 32, 71, 94.75 };
    for (widths) |width| {
        for (heights) |height| {
            const cell: Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
            const full = try init(cell, .{ .codepoint = 0x2588 });
            try std.testing.expectEqual(width * height, full.area());
            try std.testing.expectEqual(@as(f32, 1), full.coverage);
            for (0x2580..0x25a0) |cp| {
                const ink = try init(cell, .{ .codepoint = @intCast(cp) });
                try std.testing.expect(ink.count <= capacity);
                for (ink.rects[0..ink.count]) |rect| {
                    try std.testing.expect(rect.x >= 0 and rect.y >= 0 and rect.width > 0 and rect.height > 0);
                    try std.testing.expect(rect.x + rect.width <= width and rect.y + rect.height <= height);
                }

                if (ink.count == 2) {
                    const a = ink.rects[0];
                    const b = ink.rects[1];
                    const overlap = @min(a.x + a.width, b.x + b.width) > @max(a.x, b.x) and
                        @min(a.y + a.height, b.y + b.height) > @max(a.y, b.y);
                    try std.testing.expect(!overlap);
                }
            }
        }
    }
}

test "opposite slabs and complementary quadrants tile the full block at every pixel" {
    const pairs = [_][2]u21{
        .{ 0x2580, 0x2584 }, .{ 0x258c, 0x2590 }, .{ 0x2594, 0x2587 }, .{ 0x2595, 0x2589 },
        .{ 0x2596, 0x259c }, .{ 0x2597, 0x259b }, .{ 0x2598, 0x259f }, .{ 0x259d, 0x2599 }, .{ 0x259a, 0x259e },
    };
    for ([_][2]f32{ .{ 11, 21 }, .{ 8, 17 }, .{ 9, 20.5 }, .{ 1, 1 }, .{ 3, 5 }, .{ 26, 71 } }) |size| {
        const cell: Rect = .{ .x = 0, .y = 0, .width = size[0], .height = size[1] };
        for (pairs) |pair| {
            const first = try init(cell, .{ .codepoint = pair[0] });
            const second = try init(cell, .{ .codepoint = pair[1] });
            var y: f32 = 0.5;
            while (y < size[1]) : (y += 1) {
                var x: f32 = 0.5;
                while (x < size[0]) : (x += 1) {
                    try std.testing.expect(first.covered(.{ x, y }) != second.covered(.{ x, y }));
                }
            }
        }
    }
}

test "slabs grow monotonically in eighths and reach the cell edges" {
    const cell: Rect = .{ .x = 0, .y = 0, .width = 16, .height = 32 };
    var previous: f32 = 0;
    for (0x2581..0x2589) |cp| {
        const ink = try init(cell, .{ .codepoint = @intCast(cp) });
        try std.testing.expectEqual(@as(u2, 1), ink.count);
        try std.testing.expectEqual(@as(f32, 32), ink.rects[0].y + ink.rects[0].height);
        try std.testing.expectEqual(@as(f32, 16), ink.rects[0].width);
        try std.testing.expectEqual(@as(f32, @floatFromInt(4 * (cp - 0x2580))), ink.rects[0].height);
        try std.testing.expect(ink.rects[0].height > previous);
        previous = ink.rects[0].height;
    }

    previous = 16;
    for (0x2589..0x2590) |cp| {
        const ink = try init(cell, .{ .codepoint = @intCast(cp) });
        try std.testing.expectEqual(@as(f32, 0), ink.rects[0].x);
        try std.testing.expectEqual(@as(f32, @floatFromInt(2 * (0x2590 - cp))), ink.rects[0].width);
        try std.testing.expect(ink.rects[0].width < previous);
        previous = ink.rects[0].width;
    }

    const upper = try init(cell, .{ .codepoint = 0x2580 });
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 0, .width = 16, .height = 16 }, upper.rects[0]);
    const right = try init(cell, .{ .codepoint = 0x2590 });
    try std.testing.expectEqualDeep(Rect{ .x = 8, .y = 0, .width = 8, .height = 32 }, right.rects[0]);
}

test "quadrant sets merge rows and columns into at most two disjoint rectangles" {
    const cell: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 20 };
    const expected_area = [_]f32{ 50, 50, 50, 150, 100, 150, 150, 50, 100, 150 };
    for (0x2596..0x25a0, expected_area) |cp, expected| {
        const ink = try init(cell, .{ .codepoint = @intCast(cp) });
        try std.testing.expectEqual(expected, ink.area());
    }

    const full_rows = try init(cell, .{ .codepoint = 0x259b });
    try std.testing.expectEqual(@as(u2, 2), full_rows.count);
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 0, .width = 10, .height = 10 }, full_rows.rects[0]);
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 10, .width = 5, .height = 10 }, full_rows.rects[1]);
    const column = try init(cell, .{ .codepoint = 0x2598 });
    try std.testing.expectEqual(@as(u2, 1), column.count);
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 0, .width = 5, .height = 10 }, column.rects[0]);
}

test "shades cover the whole cell at 25 50 and 75 percent with one even quad per cell" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(4);
    const coverages = [_]f32{ 0.25, 0.5, 0.75 };
    for (0x2591..0x2594, coverages) |cp, coverage| {
        const ink = try init(.{ .x = 0, .y = 0, .width = 11, .height = 29 }, .{ .codepoint = @intCast(cp) });
        try std.testing.expectEqual(coverage, ink.coverage);
        try std.testing.expectEqual(@as(f32, 11 * 29), ink.area());
        list.clear();
        var run: TextRun = .{ .text = "", .x = 4, .y = 30, .color = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 0.8 }, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = -22, .width = 11, .height = 29 } };
        try ink.paint(run, &list);
        run.x += 11;
        try ink.paint(run, &list);
        const first = list.items()[0];
        const second = list.items()[1];
        try std.testing.expectEqual(@as(f32, 0.8 * coverage), first.a);
        try std.testing.expectEqual([_]f32{ 0.2, 0.4, 0.6 }, [_]f32{ first.r, first.g, first.b });
        try std.testing.expectEqual([_]f32{ 4, 8, 11, 29 }, [_]f32{ first.x, first.y, first.width, first.height });
        try std.testing.expectEqual(first.x + first.width, second.x);
        try std.testing.expectEqual([_]f32{ first.y, first.width, first.height, first.a }, [_]f32{ second.y, second.width, second.height, second.a });
    }
}

test {
    _ = @import("block_atlas_test.zig");
}
