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

// SAFETY: init fills all points for the selected shape before setting count; painting uses only that prefix.
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
pub fn rasterize(self: *const Curve, raster: Raster) void {
    const scale_x = self.width / @as(f32, @floatFromInt(raster.width));
    const scale_y = self.height / @as(f32, @floatFromInt(raster.height));
    const antialias = @max(scale_x, scale_y);
    var bounds = [4]f32{ self.width, self.height, 0, 0 };
    for (self.points[0..self.count]) |point| {
        bounds[0] = @min(bounds[0], point[0]);
        bounds[1] = @min(bounds[1], point[1]);
        bounds[2] = @max(bounds[2], point[0]);
        bounds[3] = @max(bounds[3], point[1]);
    }

    const margin = (self.thickness + antialias) / 2;
    const left: usize = @intFromFloat(std.math.clamp(@floor((bounds[0] - margin) / scale_x), 0, raster.width));
    const top: usize = @intFromFloat(std.math.clamp(@floor((bounds[1] - margin) / scale_y), 0, raster.height));
    const right: usize = @intFromFloat(std.math.clamp(@ceil((bounds[2] + margin) / scale_x), 0, raster.width));
    const bottom: usize = @intFromFloat(std.math.clamp(@ceil((bounds[3] + margin) / scale_y), 0, raster.height));
    for (0..raster.height) |row| {
        @memset(raster.pixels[row * raster.stride ..][0..raster.width], 0);
        if (row < top or row >= bottom) {
            continue;
        }

        for (left..right) |column| {
            const point = [2]f32{ (@as(f32, @floatFromInt(column)) + 0.5) * scale_x, (@as(f32, @floatFromInt(row)) + 0.5) * scale_y };
            const distance = @sqrt(self.distanceSquared(point));
            const coverage = std.math.clamp((self.thickness / 2 + antialias / 2 - distance) / antialias, 0, 1);
            raster.pixels[row * raster.stride + column] = @intFromFloat(@round(255 * coverage));
        }
    }
}

fn distanceSquared(self: *const Curve, point: [2]f32) f32 {
    var distance = std.math.inf(f32);
    const points = self.points[0..self.count];
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        distance = @min(distance, segmentDistance(point, .{ a, b }));
    }

    if (self.cross) {
        distance = @min(distance, segmentDistance(point, .{ .{ 0, self.height }, .{ self.width, 0 } }));
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
