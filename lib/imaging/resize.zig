//! Resizes straight-alpha artwork into a square with the filter the
//! direction needs: an area average when both axes shrink, bilinear when
//! either grows, so a small source never becomes blocks of repeated pixels.
//! Runs off the interactive path, like the filters it picks.
const std = @import("std");
const ImageView = @import("ImageView.zig");
const bilinear = @import("bilinear.zig");
const box_filter = @import("box_filter.zig");

/// Resizes `source` into `destination`, which holds `side * side` straight
/// RGBA pixels.
/// Example: `resize.square(image.view(), cell_pixels, 62);`
pub fn square(source: ImageView, destination: []u8, side: u32) void {
    if (source.width >= side and source.height >= side) {
        return box_filter.resample(source, destination, side);
    }

    bilinear.resample(source, destination, side);
}

test "shrinking averages areas and growing blends neighbours" {
    // Two opaque columns, black then white.
    const pixels = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 } ** 2;
    const source: ImageView = .{ .pixels = &pixels, .stride = 8, .width = 2, .height = 2 };

    var one: [4]u8 = undefined;
    square(source, &one, 1);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, &one);

    var same: [2 * 2 * 4]u8 = undefined;
    square(source, &same, 2);
    try std.testing.expectEqualSlices(u8, &pixels, &same);

    var grown: [8 * 8 * 4]u8 = undefined;
    square(source, &grown, 8);
    var greys: usize = 0;
    for (0..8) |column| {
        const value = grown[column * 4];
        greys += @intFromBool(value != 0 and value != 255);
    }

    try std.testing.expect(greys >= 2);
}
