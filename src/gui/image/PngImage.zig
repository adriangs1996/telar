//! A decoded PNG as straight-alpha RGBA8, heap-owned by whoever decoded it.
const std = @import("std");
const ImageView = @import("ImageView.zig");
const PngImage = @This();

width: u32,
height: u32,
pixels: []u8,

pub fn deinit(image: *PngImage, allocator: std.mem.Allocator) void {
    allocator.free(image.pixels);
    image.* = undefined;
}

/// The whole image as a resample source.
/// Example: `box_filter.resample(image.view(), cell_pixels, cell);`
pub fn view(image: *const PngImage) ImageView {
    return .{ .pixels = image.pixels, .stride = image.width * 4, .width = image.width, .height = image.height };
}
