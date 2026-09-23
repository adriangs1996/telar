//! Cell-aligned box geometry adapted from Ghostty font/sprite/draw/box.zig.
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
const box_lines = @import("box_lines.zig");
const BoxLines = @import("BoxLines.zig");
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Box = @import("BoxDrawing.zig");
const Grid = @This();

width: f32,
height: f32,
light: f32,
heavy: f32,
rects: [8]Rect = undefined,
count: u4 = 0,

/// Bounds include configured spacing. Strokes remain inside tiny cells.
/// Example: `const grid = try BoxGrid.init(cell, 2);`
pub fn init(cell: Rect, thickness: f32) !Grid {
    if (!std.math.isFinite(cell.x) or !std.math.isFinite(cell.y) or
        !std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or
        cell.width < 0 or cell.height < 0 or cell.width > 65535 or cell.height > 65535 or
        !std.math.isFinite(thickness) or thickness <= 0)
    {
        return error.InvalidCellBounds;
    }

    const minimum = @min(cell.width, cell.height);
    return .{ .width = cell.width, .height = cell.height, .light = @min(minimum, thickness), .heavy = @min(minimum, 2 * thickness) };
}

/// Emits the specified arms or dash pattern; curves are rasterized separately.
/// Example: `grid.draw(box);`
pub fn draw(self: *Grid, box: Box) void {
    if (box_lines.get(box.codepoint)) |lines| {
        var resolved = lines;
        if (@min(self.width, self.height) < 3 * self.light) {
            // Two strokes and their gap need three units; a single stroke keeps
            // undersized cells visible instead of clipping both strokes away.
            inline for (.{ "up", "right", "down", "left" }) |field| {
                if (@field(resolved, field) == .double) {
                    @field(resolved, field) = .light;
                }
            }
        }

        self.intersection(resolved);
        return;
    }

    const cp = box.codepoint;
    const count: u8 = if (cp >= 0x254c) 2 else if (cp >= 0x2508) 4 else 3;
    const vertical = cp & 2 != 0;
    const heavy = cp & 1 != 0;
    const thickness = if (heavy) self.heavy else self.light;
    const desired_gap = if (count != 2) @max(4, self.light) else if (cp == 0x254c) self.light else self.heavy;
    const extent = if (vertical) self.height else self.width;
    const across = if (vertical) self.width else self.height;
    const center = @max(0, @floor((across - thickness) / 2));
    if (extent < 2 * @as(f32, @floatFromInt(count))) {
        self.add(if (vertical) .{ center, 0, center + thickness, extent } else .{ 0, center, extent, center + thickness });
        return;
    }

    const gap = @min(desired_gap, @floor(extent / (2 * @as(f32, @floatFromInt(count)))));
    const total = extent - gap * @as(f32, @floatFromInt(count));
    const dash = @floor(total / @as(f32, @floatFromInt(count)));
    var remainder = total - dash * @as(f32, @floatFromInt(count));
    var start: f32 = if (vertical) 0 else @floor(gap / 2);
    for (0..count) |_| {
        const extra = @min(1, remainder);
        remainder -= extra;
        const end = start + dash + extra;
        self.add(if (vertical) .{ center, start, center + thickness, end } else .{ start, center, end, center + thickness });
        start = end + gap;
    }
}

fn add(self: *Grid, edges: [4]f32) void {
    const left = std.math.clamp(edges[0], 0, self.width);
    const top = std.math.clamp(edges[1], 0, self.height);
    const right = std.math.clamp(edges[2], left, self.width);
    const bottom = std.math.clamp(edges[3], top, self.height);
    if (right == left or bottom == top) {
        return;
    }

    self.rects[self.count] = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    self.count += 1;
}

fn intersection(self: *Grid, lines: BoxLines.Lines) void {
    const light_px = self.light;
    const heavy_px = self.heavy;

    // Top of light horizontal strokes
    const h_light_top = @floor((self.height - light_px) / 2);
    // Bottom of light horizontal strokes
    const h_light_bottom = h_light_top + light_px;

    // Top of heavy horizontal strokes
    const h_heavy_top = @floor((self.height - heavy_px) / 2);
    // Bottom of heavy horizontal strokes
    const h_heavy_bottom = h_heavy_top + heavy_px;

    // Top of the top doubled horizontal stroke (bottom is `h_light_top`)
    const h_double_top = h_light_top - light_px;
    // Bottom of the bottom doubled horizontal stroke (top is `h_light_bottom`)
    const h_double_bottom = h_light_bottom + light_px;

    // Left of light vertical strokes
    const v_light_left = @floor((self.width - light_px) / 2);
    // Right of light vertical strokes
    const v_light_right = v_light_left + light_px;

    // Left of heavy vertical strokes
    const v_heavy_left = @floor((self.width - heavy_px) / 2);
    // Right of heavy vertical strokes
    const v_heavy_right = v_heavy_left + heavy_px;

    // Left of the left doubled vertical stroke (right is `v_light_left`)
    const v_double_left = v_light_left - light_px;
    // Right of the right doubled vertical stroke (left is `v_light_right`)
    const v_double_right = v_light_right + light_px;

    // The bottom of the up line
    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double)
            h_double_bottom
        else
            h_light_bottom
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    // The top of the down line
    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double)
            h_double_top
        else
            h_light_top
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    // The right of the left line
    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double)
            v_double_right
        else
            v_light_right
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    // The left of the right line
    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double)
            v_double_left
        else
            v_light_left
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    switch (lines.up) {
        .none => {},
        .light => self.add(.{ v_light_left, 0, v_light_right, up_bottom }),
        .heavy => self.add(.{ v_heavy_left, 0, v_heavy_right, up_bottom }),
        .double => {
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;

            self.add(.{ v_double_left, 0, v_light_left, left_bottom });
            self.add(.{ v_light_right, 0, v_double_right, right_bottom });
        },
    }

    switch (lines.right) {
        .none => {},
        .light => self.add(.{ right_left, h_light_top, self.width, h_light_bottom }),
        .heavy => self.add(.{ right_left, h_heavy_top, self.width, h_heavy_bottom }),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;

            self.add(.{ top_left, h_double_top, self.width, h_light_top });
            self.add(.{ bottom_left, h_light_bottom, self.width, h_double_bottom });
        },
    }

    switch (lines.down) {
        .none => {},
        .light => self.add(.{ v_light_left, down_top, v_light_right, self.height }),
        .heavy => self.add(.{ v_heavy_left, down_top, v_heavy_right, self.height }),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;

            self.add(.{ v_double_left, left_top, v_light_left, self.height });
            self.add(.{ v_light_right, right_top, v_double_right, self.height });
        },
    }

    switch (lines.left) {
        .none => {},
        .light => self.add(.{ 0, h_light_top, left_right, h_light_bottom }),
        .heavy => self.add(.{ 0, h_heavy_top, left_right, h_heavy_bottom }),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;

            self.add(.{ 0, h_double_top, top_right, h_light_top });
            self.add(.{ 0, h_light_bottom, bottom_right, h_double_bottom });
        },
    }
}

test "invalid box metrics are rejected before geometry or integer conversion" {
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32), 65536 }) |size| {
        try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = 0, .y = 0, .width = size, .height = 32 }, 1));
        try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = 0, .y = 0, .width = 16, .height = size }, 1));
    }

    for ([_]f32{ -1, 0, std.math.nan(f32), std.math.inf(f32) }) |thickness| {
        try std.testing.expectError(error.InvalidCellBounds, init(.{ .x = 0, .y = 0, .width = 16, .height = 32 }, thickness));
    }
}

test "double boxes remain visible when a cell cannot fit two strokes and a gap" {
    for ([_]f32{ 0.25, 0.5, 1, 2, 3 }) |size| {
        for ([_]u21{ 0x2550, 0x2551, 0x2554, 0x256c }) |codepoint| {
            var grid = try init(.{ .x = 0, .y = 0, .width = size, .height = size }, 1);
            grid.draw(.{ .codepoint = codepoint });
            try std.testing.expect(grid.count > 0);
        }
    }
}
