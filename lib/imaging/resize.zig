//! Resizes straight-alpha artwork into a square with the filter the
//! direction needs: an area average when both axes shrink, bilinear when
//! either grows, so a small source never becomes blocks of repeated pixels.
//! Runs off the interactive path, like the filters it picks.
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
