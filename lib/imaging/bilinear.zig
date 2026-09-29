//! Bilinear resample of straight-alpha RGBA artwork.
//!
//! Every destination pixel blends the four source pixels around its centre,
//! weighted by their alpha, so a transparent neighbour never bleeds its
//! colour into an edge. Enlarging a small icon this way gives soft edges
//! instead of the blocks a box filter replicates. Runs off the interactive
//! path, in the favicon worker and at sprite page construction.
const std = @import("std");
const ImageView = @import("ImageView.zig");

/// Resamples `source` into `destination`, which holds `side * side` straight
/// RGBA pixels.
/// Example: `bilinear.resample(image.view(), page_cell, 62);`
pub fn resample(source: ImageView, destination: []u8, side: u32) void {
    resampleRect(source, destination, side, side);
}

/// Resamples `source` into `destination`, which holds `width * height`
/// straight RGBA pixels. Pixel centres map onto pixel centres and the
/// border repeats, like a GPU's linear filter clamped to the edge.
/// Example: `bilinear.resampleRect(image.view(), pixels, 64, 48);`
pub fn resampleRect(source: ImageView, destination: []u8, width: u32, height: u32) void {
    std.debug.assert(destination.len == @as(usize, width) * height * 4);
    std.debug.assert(source.width != 0 and source.height != 0 and width != 0 and height != 0);
    for (0..height) |row| {
        const y = Tap.of(@intCast(row), height, source.height);
        for (0..width) |column| {
            const x = Tap.of(@intCast(column), width, source.width);
            const pixels = [4][4]u8{
                source.pixel(x.index, y.index),
                source.pixel(x.next, y.index),
                source.pixel(x.index, y.next),
                source.pixel(x.next, y.next),
            };
            const weights = [4]f32{
                (1 - x.fraction) * (1 - y.fraction),
                x.fraction * (1 - y.fraction),
                (1 - x.fraction) * y.fraction,
                x.fraction * y.fraction,
            };

            var alpha: f32 = 0;
            var premultiplied: [3]f32 = .{ 0, 0, 0 };
            for (pixels, weights) |rgba, weight| {
                const a = @as(f32, @floatFromInt(rgba[3])) * weight;
                alpha += a;
                inline for (0..3) |channel| {
                    premultiplied[channel] += @as(f32, @floatFromInt(rgba[channel])) * a;
                }
            }

            const out = destination[(row * width + column) * 4 ..][0..4];
            out.* = .{ 0, 0, 0, 0 };
            if (alpha <= 0) {
                continue;
            }

            out[3] = @intFromFloat(@min(255, @round(alpha)));
            inline for (0..3) |channel| {
                out[channel] = @intFromFloat(@min(255, @round(premultiplied[channel] / alpha)));
            }
        }
    }
}

test "a flat bitmap resamples to its own colour at any size" {
    const pixels = [_]u8{ 10, 200, 30, 255 } ** 16;
    const source: ImageView = .{ .pixels = &pixels, .stride = 16, .width = 4, .height = 4 };
    for ([_]u32{ 1, 3, 4, 7 }) |side| {
        var out: [7 * 7 * 4]u8 = undefined;
        resample(source, out[0 .. side * side * 4], side);
        for (0..side * side) |index| {
            try std.testing.expectEqualSlices(u8, &.{ 10, 200, 30, 255 }, out[index * 4 ..][0..4]);
        }
    }
}

test "an enlarged edge ramps its alpha instead of repeating blocks" {
    // Left column opaque red, right column transparent black, 2x1 into 8x1.
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0 };
    const source: ImageView = .{ .pixels = &pixels, .stride = 8, .width = 2, .height = 1 };
    var out: [8 * 1 * 4]u8 = undefined;
    resampleRect(source, &out, 8, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[28..32]);
    var previous: u8 = 255;
    var steps: usize = 0;
    for (0..8) |column| {
        const alpha = out[column * 4 + 3];
        try std.testing.expect(alpha <= previous);
        steps += @intFromBool(alpha != previous);
        if (alpha != 0) {
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, out[column * 4 ..][0..3]);
        }

        previous = alpha;
    }

    // A box filter would jump once, from 255 straight to 0.
    try std.testing.expect(steps >= 3);
}

test "a region samples only inside its origin" {
    const pixels = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 } ++
        [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    const right: ImageView = .{ .pixels = &pixels, .stride = 16, .x = 2, .width = 2, .height = 2 };
    var out: [5 * 5 * 4]u8 = undefined;
    resample(right, &out, 5);
    for (0..25) |index| {
        try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, out[index * 4 ..][0..4]);
    }
}

/// The two source pixels one destination index blends on one axis and the
/// weight of the second.
const Tap = struct {
    index: u32,
    next: u32,
    fraction: f32,

    /// The pixels around the centre of destination `index` of `side` over
    /// `source_extent`, clamped to the border.
    /// Example: `const x = Tap.of(column, width, source.width);`
    pub fn of(index: u32, side: u32, source_extent: u32) Tap {
        const scale = @as(f32, @floatFromInt(source_extent)) / @as(f32, @floatFromInt(side));
        const centre = @max(0, (@as(f32, @floatFromInt(index)) + 0.5) * scale - 0.5);
        const first: u32 = @min(source_extent - 1, @as(u32, @intFromFloat(@floor(centre))));
        return .{
            .index = first,
            .next = @min(source_extent - 1, first + 1),
            .fraction = @min(1, centre - @as(f32, @floatFromInt(first))),
        };
    }
};
