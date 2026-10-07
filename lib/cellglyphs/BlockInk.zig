//! Solid rectangles for one block element, measured from the complete cell so
//! ink meets every cell edge regardless of line height or letter spacing.
const std = @import("std");
const gfx = @import("gfx");
const Color = gfx.Color;
const QuadList = gfx.QuadList;
const Rect = gfx.Rect;
const Block = @import("BlockElement.zig");
const block_shapes = @import("block_shapes.zig");
const BlockSlab = @import("BlockSlab.zig");
const Ink = @This();

pub const capacity = 2;
// SAFETY: Shape construction appends rectangles before count advances; paint reads only rects[0..count].
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

/// Places the rectangles in `cell`, the cell's rectangle in device pixels;
/// bold and italic do not deform the geometry.
/// Example: `try ink.paint(cell, color, list);`
pub fn paint(self: *const Ink, cell: Rect, color: Color, list: *QuadList) !void {
    var shaded = color;
    shaded.a *= self.coverage;
    for (self.rects[0..self.count]) |rect| {
        var placed = rect;
        placed.x += cell.x;
        placed.y += cell.y;
        try list.pushRect(placed, shaded);
    }
}

fn slab(self: *Ink, cell: Rect, shape: BlockSlab) void {
    switch (shape.side) {
        .top => self.append(.{ .x = 0, .y = 0, .width = cell.width, .height = split(cell.height, shape.eighths) }),
        .bottom => {
            const top = split(cell.height, 8 - shape.eighths);
            self.append(.{ .x = 0, .y = top, .width = cell.width, .height = cell.height - top });
        },
        .left => self.append(.{ .x = 0, .y = 0, .width = split(cell.width, shape.eighths), .height = cell.height }),
        .right => {
            const left = split(cell.width, 8 - shape.eighths);
            self.append(.{ .x = left, .y = 0, .width = cell.width - left, .height = cell.height });
        },
    }
}

fn quadrants(self: *Ink, cell: Rect, mask: u4) void {
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
            self.append(.{ .x = x, .y = top, .width = right_edge - x, .height = bottom - top });
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

fn append(self: *Ink, rect: Rect) void {
    if (rect.width <= 0 or rect.height <= 0) {
        return;
    }

    if (self.count > 0) {
        const previous = &self.rects[self.count - 1];
        if (previous.x == rect.x and previous.width == rect.width and previous.y + previous.height == rect.y) {
            previous.height += rect.height;
            return;
        }
    }

    std.debug.assert(self.count < capacity);
    self.rects[self.count] = rect;
    self.count += 1;
}
