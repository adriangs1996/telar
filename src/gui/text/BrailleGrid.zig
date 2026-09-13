//! Braille dot geometry, adapted from Ghostty font/sprite/draw/braille.zig.
//! Integer cell layout follows Ghostty; subpixel cells stay inside their bounds.
// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Grid = @This();

x: [2]f32,
y: [4]f32,
diameter: f32,

/// Produces up to eight disjoint dot boxes in the supplied physical cell.
/// Example: `const grid = try BrailleGrid.init(cell);`
pub fn init(cell: Rect) !Grid {
    if (!std.math.isFinite(cell.x) or !std.math.isFinite(cell.y) or
        !std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or
        cell.width < 0 or cell.height < 0 or cell.width > 65535 or cell.height > 65535)
    {
        return error.InvalidCellBounds;
    }

    if (cell.width < 2 or cell.height < 4) {
        const diameter = @min(cell.width / 2, cell.height / 4);
        return .{
            .x = .{ cell.x + cell.width / 4 - diameter / 2, cell.x + 3 * cell.width / 4 - diameter / 2 },
            .y = .{ cell.y + cell.height / 8 - diameter / 2, cell.y + 3 * cell.height / 8 - diameter / 2, cell.y + 5 * cell.height / 8 - diameter / 2, cell.y + 7 * cell.height / 8 - diameter / 2 },
            .diameter = diameter,
        };
    }

    const width: i32 = @intFromFloat(cell.width);
    const height: i32 = @intFromFloat(cell.height);
    var diameter = @min(@divFloor(width, 4), @divFloor(height, 8));
    var x_spacing = @divFloor(width, 4);
    var y_spacing = @divFloor(height, 8);
    var x_margin = @divFloor(x_spacing, 2);
    var y_margin = @divFloor(y_spacing, 2);
    var x_remaining = width - 2 * x_margin - x_spacing - 2 * diameter;
    var y_remaining = height - 2 * y_margin - 3 * y_spacing - 4 * diameter;
    if (x_remaining >= 2 and y_remaining >= 4 and diameter == 0) {
        diameter += 1;
        x_remaining -= 2;
        y_remaining -= 4;
    }

    if (x_remaining >= 2 and x_margin == 0) {
        x_margin = 1;
        x_remaining -= 2;
    }

    if (y_remaining >= 2 and y_margin == 0) {
        y_margin = 1;
        y_remaining -= 2;
    }

    if (x_remaining >= 1) {
        x_spacing += 1;
        x_remaining -= 1;
    }

    if (y_remaining >= 3) {
        y_spacing += 1;
        y_remaining -= 3;
    }

    if (x_remaining >= 2) {
        x_margin += 1;
        x_remaining -= 2;
    }

    if (y_remaining >= 2) {
        y_margin += 1;
        y_remaining -= 2;
    }

    if (x_remaining >= 2 and y_remaining >= 4) {
        diameter += 1;
    }

    return .{
        .x = .{ cell.x + @as(f32, @floatFromInt(x_margin)), cell.x + @as(f32, @floatFromInt(x_margin + diameter + x_spacing)) },
        .y = .{ cell.y + @as(f32, @floatFromInt(y_margin)), cell.y + @as(f32, @floatFromInt(y_margin + diameter + y_spacing)), cell.y + @as(f32, @floatFromInt(y_margin + 2 * (diameter + y_spacing))), cell.y + @as(f32, @floatFromInt(y_margin + 3 * (diameter + y_spacing))) },
        .diameter = @floatFromInt(diameter),
    };
}

test "line spacing follows Ghostty integer cell geometry" {
    const grid = try init(.{ .x = 0, .y = 0, .width = 26, .height = 71 });
    try std.testing.expectEqual(@as(f32, 6), grid.diameter);
    try std.testing.expectEqual([_]f32{ 4, 17 }, grid.x);
    try std.testing.expectEqual([_]f32{ 5, 20, 35, 50 }, grid.y);
}

test "small fractional cells keep each dot inside the cell" {
    for (0..129) |width| {
        for (0..257) |height| {
            const cell: Rect = .{ .x = -2.5, .y = 7.25, .width = @as(f32, @floatFromInt(width)) / 4, .height = @as(f32, @floatFromInt(height)) / 4 };
            const grid = try init(cell);
            try std.testing.expect(std.math.isFinite(grid.diameter) and grid.diameter >= 0);
            for (grid.x) |x| {
                try std.testing.expect(x >= cell.x and x + grid.diameter <= cell.x + cell.width);
            }

            for (grid.y) |y| {
                try std.testing.expect(y >= cell.y and y + grid.diameter <= cell.y + cell.height);
            }

            try std.testing.expect(grid.x[0] + grid.diameter <= grid.x[1]);
            for (0..3) |row| {
                try std.testing.expect(grid.y[row] + grid.diameter <= grid.y[row + 1]);
            }
        }
    }
}

test "invalid Braille cells are rejected before integer conversion" {
    const invalid = [_]f32{ -1, std.math.nan(f32), std.math.inf(f32), 65536 };
    for (invalid) |extent| {
        try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = 0, .y = 0, .width = extent, .height = 32 }));
        try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = 0, .y = 0, .width = 16, .height = extent }));
    }

    try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = std.math.inf(f32), .y = 0, .width = 16, .height = 32 }));
}
