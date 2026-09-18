//! Premultiplied RGBA owned by the GUI until every frame consumer has finished.
const std = @import("std");
const Image = @This();

pub const max_side = 4096;
pub const max_pixels = 4 * 1024 * 1024;

width: u32,
height: u32,
logical_width: f32,
logical_height: f32,
pixels: []u8,
/// The protocol buffer may include its 24-byte header before `pixels`.
allocation: ?[]u8 = null,

/// Example: `defer image.deinit(allocator);`
pub fn deinit(image: *Image, allocator: std.mem.Allocator) void {
    allocator.free(image.allocation orelse image.pixels);
    image.* = undefined;
}

/// Validates dimensions before exposing bytes to a native GPU backend.
/// Example: `if (!image.valid()) return error.DiagramLimit;`
pub fn valid(image: Image) bool {
    return image.width > 0 and image.height > 0 and image.width <= max_side and image.height <= max_side and
        @as(u64, image.width) * image.height <= max_pixels and image.pixels.len == @as(u64, image.width) * image.height * 4 and
        std.math.isFinite(image.logical_width) and std.math.isFinite(image.logical_height) and
        image.logical_width > 0 and image.logical_height > 0 and image.logical_width <= 1_000_000 and image.logical_height <= 1_000_000;
}
