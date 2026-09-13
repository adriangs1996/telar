//! Rounded box corners and diagonals rasterized into a bounded alpha mask.
//! Corner paths follow Ghostty font/sprite/draw/box.zig; sixteen line segments
//! approximate its cubic curve before analytic pixel-center coverage.
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
const Grid = @import("BoxGrid.zig");
const Raster = @import("BoxRaster.zig");
const Curve = @This();

points: [19][2]f32 = undefined,
count: u5 = 0,
width: f32,
height: f32,
thickness: f32,
cross: bool = false,

/// Builds one of four corners or three diagonals using the cell's stroke centers.
/// Example: `const curve = BoxCurve.init(grid, 0);`.
pub fn init(grid: Grid, shape: u3) Curve {
    var curve: Curve = .{ .width = grid.width, .height = grid.height, .thickness = grid.light };
    if (shape >= 4) {
        curve.points[0] = .{ 0, if (shape == 4) grid.height else 0 };
        curve.points[1] = .{ grid.width, if (shape == 4) 0 else grid.height };
        curve.count = 2;
        curve.cross = shape == 6;
        return curve;
    }

    const right = shape == 0 or shape == 3;
    const down = shape == 0 or shape == 1;
    const sx: f32 = if (right) 1 else -1;
    const sy: f32 = if (down) 1 else -1;
    const cx = @floor((grid.width - grid.light) / 2) + grid.light / 2;
    const cy = @floor((grid.height - grid.light) / 2) + grid.light / 2;
    const radius = @min(grid.width, grid.height) / 2;
    curve.points[0] = .{ cx, if (down) grid.height else 0 };
    for (0..17) |step| {
        const t = @as(f32, @floatFromInt(step)) / 16;
        const u = 1 - t;
        curve.points[step + 1] = .{
            cx + sx * radius * (0.75 * u * t * t + t * t * t),
            cy + sy * radius * (u * u * u + 0.75 * u * u * t),
        };
    }

    curve.points[18] = .{ if (right) grid.width else 0, cy };
    curve.count = 19;
    return curve;
}

/// Writes one mask; work is capped by the caller's raster extent, never the pane.
/// Example: `curve.rasterize(.{ .pixels = pixels, .stride = side, .width = 26, .height = 71 });`
pub fn rasterize(curve: *const Curve, raster: Raster) void {
    const scale_x = curve.width / @as(f32, @floatFromInt(raster.width));
    const scale_y = curve.height / @as(f32, @floatFromInt(raster.height));
    const antialias = @max(scale_x, scale_y);
    for (0..raster.height) |row| {
        for (0..raster.width) |column| {
            const point = [2]f32{ (@as(f32, @floatFromInt(column)) + 0.5) * scale_x, (@as(f32, @floatFromInt(row)) + 0.5) * scale_y };
            const distance = @sqrt(curve.distanceSquared(point));
            const coverage = std.math.clamp((curve.thickness / 2 + antialias / 2 - distance) / antialias, 0, 1);
            raster.pixels[row * raster.stride + column] = @intFromFloat(@round(255 * coverage));
        }
    }
}

fn distanceSquared(curve: *const Curve, point: [2]f32) f32 {
    var distance = std.math.inf(f32);
    const points = curve.points[0..curve.count];
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        distance = @min(distance, segmentDistance(point, .{ a, b }));
    }

    if (curve.cross) {
        distance = @min(distance, segmentDistance(point, .{ .{ 0, curve.height }, .{ curve.width, 0 } }));
    }

    return distance;
}

fn segmentDistance(point: [2]f32, segment: [2][2]f32) f32 {
    const a = segment[0];
    const b = segment[1];
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length = dx * dx + dy * dy;
    const t = if (length == 0) 0 else std.math.clamp(((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length, 0, 1);
    const x = point[0] - a[0] - t * dx;
    const y = point[1] - a[1] - t * dy;
    return x * x + y * y;
}

test "rounded corners and diagonals have antialias coverage and meet their cell edges" {
    const grid = try Grid.init(.{ .x = 0, .y = 0, .width = 26, .height = 71 }, 2);
    var pixels: [26 * 71]u8 = undefined;
    for (0..7) |shape| {
        const curve = init(grid, @intCast(shape));
        curve.rasterize(.{ .pixels = &pixels, .stride = 26, .width = 26, .height = 71 });
        var partial: usize = 0;
        for (pixels) |alpha| {
            partial += @intFromBool(alpha != 0 and alpha != 255);
        }

        try std.testing.expect(partial > 0);
        if (shape < 4) {
            const right = shape == 0 or shape == 3;
            const down = shape == 0 or shape == 1;
            try std.testing.expectEqual(@as(u8, 255), pixels[(if (down) @as(usize, 70) else 0) * 26 + 12]);
            try std.testing.expect(pixels[34 * 26 + (if (right) @as(usize, 25) else 0)] >= 240);
            try std.testing.expectEqual(@as(u8, 0), pixels[34 * 26 + 12]);
        } else {
            const x: usize = if (shape == 4) 25 else 0;
            try std.testing.expect(pixels[x] > 0);
            try std.testing.expect(pixels[70 * 26 + 25 - x] > 0);
        }
    }
}

test "fractional and tiny box curves never write outside the supplied raster" {
    var storage: [17]u8 = @splat(37);
    const sizes = [_]f32{ 0.25, 0.5, 1, 1.75, 3 };
    for (sizes) |width| {
        for (sizes) |height| {
            const grid = try Grid.init(.{ .x = 0, .y = 0, .width = width, .height = height }, 3);
            for (0..7) |shape| {
                const curve = init(grid, @intCast(shape));
                curve.rasterize(.{ .pixels = storage[1..], .stride = 4, .width = 3, .height = 3 });
                try std.testing.expectEqual(@as(u8, 37), storage[0]);
                try std.testing.expectEqual(@as(u8, 37), storage[4]);
                try std.testing.expectEqual(@as(u8, 37), storage[8]);
                try std.testing.expectEqual(@as(u8, 37), storage[12]);
                try std.testing.expectEqual(@as(u8, 37), storage[16]);
            }
        }
    }
}
