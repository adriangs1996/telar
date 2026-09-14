//! Area-averaging resample of straight-alpha artwork into a square cell.
//! Every source pixel contributes the fraction of the destination pixel it
//! covers, weighted by its alpha, so a transparent neighbour never bleeds
//! colour into an edge. Reads each source pixel once: O(source area).
//! Runs off the interactive path: at startup for the provider sheet and in
//! the favicon worker for decoded files.
const std = @import("std");
const ImageView = @import("ImageView.zig");
const FilterSpan = @import("FilterSpan.zig");

/// Resamples `source` into `destination`, which holds `side * side` straight
/// RGBA pixels. Upscaling replicates source pixels with fractional edges.
/// Example: `box_filter.resample(slot, page_cell, 32);`
pub fn resample(source: ImageView, destination: []u8, side: u32) void {
    std.debug.assert(destination.len == @as(usize, side) * side * 4);
    std.debug.assert(source.width != 0 and source.height != 0 and side != 0);
    for (0..side) |row| {
        const rows = FilterSpan.of(@intCast(row), side, source.height);
        for (0..side) |column| {
            const columns = FilterSpan.of(@intCast(column), side, source.width);
            var alpha: f32 = 0;
            var premultiplied: [3]f32 = .{ 0, 0, 0 };
            var total: f32 = 0;
            var y = rows.first;
            while (y < rows.end) : (y += 1) {
                const row_weight = rows.weight(y);
                var x = columns.first;
                while (x < columns.end) : (x += 1) {
                    const weight = row_weight * columns.weight(x);
                    const rgba = source.pixel(x, y);
                    const a = @as(f32, @floatFromInt(rgba[3])) * weight;
                    alpha += a;
                    total += weight;
                    inline for (0..3) |channel| {
                        premultiplied[channel] += @as(f32, @floatFromInt(rgba[channel])) * a;
                    }
                }
            }

            const out = destination[(row * side + column) * 4 ..][0..4];
            out.* = .{ 0, 0, 0, 0 };
            if (alpha <= 0 or total <= 0) {
                continue;
            }

            out[3] = @intFromFloat(@min(255, @round(alpha / total)));
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

test "a downscale averages coverage and keeps opaque colour beside transparency" {
    // Left half opaque red, right half transparent black, 4x2 into 2x2 then 1x1.
    const pixels = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0 } ** 2;
    const source: ImageView = .{ .pixels = &pixels, .stride = 16, .width = 4, .height = 2 };
    var two: [2 * 2 * 4]u8 = undefined;
    resample(source, &two, 2);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, two[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, two[4..8]);
    var one: [4]u8 = undefined;
    resample(source, &one, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, &one);
}

test "a region samples only inside its origin" {
    const pixels = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 } ++
        [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    const right: ImageView = .{ .pixels = &pixels, .stride = 16, .x = 2, .width = 2, .height = 2 };
    var out: [3 * 3 * 4]u8 = undefined;
    resample(right, &out, 3);
    for (0..9) |index| {
        try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, out[index * 4 ..][0..4]);
    }
}
