//! Bilinear sampling of straight-alpha RGBA artwork.
//!
//! Weights are premultiplied by alpha, so a transparent neighbour never
//! bleeds its color into an edge. One square region of a bitmap maps onto
//! one square of destination pixels; this is how embedded artwork reaches
//! the size of a terminal cell.

const std = @import("std");

pub const Point = struct {
    x: u32,
    y: u32,
};

/// A square region of an RGBA pixel store.
pub const Bitmap = struct {
    pixels: []const u8,
    /// Row stride of the store, in pixels.
    stride: u32,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
    side: u32,

    fn pixel(bitmap: Bitmap, x: u32, y: u32) [4]u8 {
        const index = (@as(usize, bitmap.origin_y + y) * bitmap.stride + bitmap.origin_x + x) * 4;
        return bitmap.pixels[index..][0..4].*;
    }
};

const Axis = struct {
    index: u32,
    next: u32,
    fraction: u64,
};

const one: u64 = 1 << 16;

/// The straight-alpha color of destination pixel `point` when the bitmap's
/// square is scaled to `size` pixels a side.
/// For example: `const rgba = bitmap.sample(source, .{ .x = 3, .y = 4 }, 20);`.
pub fn sample(source: Bitmap, point: Point, size: u32) [4]u8 {
    const x = axis(point.x, size, source.side);
    const y = axis(point.y, size, source.side);
    const weights = [4]u64{
        (one - x.fraction) * (one - y.fraction),
        x.fraction * (one - y.fraction),
        (one - x.fraction) * y.fraction,
        x.fraction * y.fraction,
    };
    const pixels = [4][4]u8{
        source.pixel(x.index, y.index),
        source.pixel(x.next, y.index),
        source.pixel(x.index, y.next),
        source.pixel(x.next, y.next),
    };

    const total_weight: u64 = one * one;
    var alpha_sum: u64 = 0;
    var premultiplied: [3]u64 = @splat(0);
    for (pixels, weights) |pixel, weight| {
        alpha_sum += @as(u64, pixel[3]) * weight;
        inline for (0..3) |channel| {
            premultiplied[channel] += @as(u64, pixel[channel]) * pixel[3] * weight;
        }
    }

    var out: [4]u8 = @splat(0);
    out[3] = @intCast((alpha_sum + total_weight / 2) / total_weight);
    if (alpha_sum == 0) {
        return out;
    }

    inline for (0..3) |channel| {
        out[channel] = @intCast((premultiplied[channel] + alpha_sum / 2) / alpha_sum);
    }

    return out;
}

fn axis(destination: u32, destination_size: u32, source_side: u32) Axis {
    const source_last = source_side - 1;
    if (destination_size <= 1) {
        return .{ .index = source_last / 2, .next = source_last / 2, .fraction = 0 };
    }

    const fixed = @as(u64, destination) * source_last * one / (destination_size - 1);
    const index: u32 = @intCast(fixed >> 16);
    return .{
        .index = index,
        .next = @min(source_last, index + 1),
        .fraction = fixed & 0xffff,
    };
}

test "a flat bitmap samples to its own color at any size" {
    const pixels = [_]u8{ 10, 200, 30, 255 } ** 16;
    const source: Bitmap = .{ .pixels = &pixels, .stride = 4, .side = 4 };
    try std.testing.expectEqualSlices(u8, &.{ 10, 200, 30, 255 }, &sample(source, .{ .x = 0, .y = 0 }, 1));
    try std.testing.expectEqualSlices(u8, &.{ 10, 200, 30, 255 }, &sample(source, .{ .x = 5, .y = 2 }, 7));
}

test "transparent neighbours fade the alpha without darkening the color" {
    // Left column opaque red, right column transparent black.
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0 };
    const source: Bitmap = .{ .pixels = &pixels, .stride = 2, .side = 2 };
    const edge = sample(source, .{ .x = 1, .y = 0 }, 3);
    try std.testing.expectEqual(@as(u8, 255), edge[0]);
    try std.testing.expectEqual(@as(u8, 0), edge[1]);
    try std.testing.expect(edge[3] > 100 and edge[3] < 156);
}

test "a region samples only inside its origin" {
    // Two 2x2 squares side by side: black then white.
    const pixels = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 } ++
        [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    const right: Bitmap = .{ .pixels = &pixels, .stride = 4, .origin_x = 2, .side = 2 };
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &sample(right, .{ .x = 1, .y = 1 }, 2));
}
