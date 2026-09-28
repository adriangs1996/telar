//! Premultiplied RGBA8 pixels the window samples as one texture. Clipboard
//! images may hold private content, so `deinit` zeroes the pixels before
//! freeing them.
const std = @import("std");
const PremultipliedImage = @This();

width: u32,
height: u32,
pixels: []u8,

/// Allocates `width * height` transparent pixels.
/// Example: `var image = try PremultipliedImage.init(gpa, 256, 144);`
pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !PremultipliedImage {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    @memset(pixels, 0);
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

/// Example: `image.deinit(gpa);`
pub fn deinit(self: *PremultipliedImage, gpa: std.mem.Allocator) void {
    std.crypto.secureZero(u8, self.pixels);
    gpa.free(self.pixels);
    self.* = undefined;
}
