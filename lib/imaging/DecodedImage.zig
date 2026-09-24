//! A decoded image as straight-alpha RGBA8, heap-owned by whoever decoded it.
const std = @import("std");
const ImageView = @import("ImageView.zig");
const DecodedImage = @This();

width: u32,
height: u32,
pixels: []u8,

pub fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
    allocator.free(self.pixels);
    self.* = undefined;
}

/// The whole image as a resample source.
/// Example: `box_filter.resample(image.view(), cell_pixels, cell);`
pub fn view(self: *const DecodedImage) ImageView {
    return .{ .pixels = self.pixels, .stride = self.width * 4, .width = self.width, .height = self.height };
}
