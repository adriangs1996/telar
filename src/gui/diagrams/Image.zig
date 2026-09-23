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
pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
    allocator.free(self.allocation orelse self.pixels);
    self.* = undefined;
}

/// Validates dimensions before exposing bytes to a native GPU backend.
/// Example: `if (!image.valid()) return error.DiagramLimit;`
pub fn valid(self: Image) bool {
    return self.width > 0 and self.height > 0 and self.width <= max_side and self.height <= max_side and
        @as(u64, self.width) * self.height <= max_pixels and self.pixels.len == @as(u64, self.width) * self.height * 4 and
        std.math.isFinite(self.logical_width) and std.math.isFinite(self.logical_height) and
        self.logical_width > 0 and self.logical_height > 0 and self.logical_width <= 1_000_000 and self.logical_height <= 1_000_000;
}
