const std = @import("std");
const Pixel = @import("Pixel.zig");
const Color = @import("Color.zig");
const Frame = @This();

pixels: []u8,
width: usize,
height: usize,

pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Frame {
    const pixel_count = try std.math.mul(usize, width, height);
    const byte_count = try std.math.mul(usize, pixel_count, 4);
    const pixels = try allocator.alloc(u8, byte_count);

    return Frame{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *const Frame, allocator: std.mem.Allocator) void {
    allocator.free(self.pixels);
}

pub fn setPixel(self: *Frame, pixel: Pixel) void {
    if (pixel.x < 0 or pixel.y < 0) {
        return;
    }

    const x: usize = @intCast(pixel.x);
    const y: usize = @intCast(pixel.y);

    if (x >= self.width or y >= self.height) {
        return;
    }

    const offset = (x + y * self.width) * 4;
    self.pixels[offset] = pixel.r;
    self.pixels[offset + 1] = pixel.g;
    self.pixels[offset + 2] = pixel.b;
    self.pixels[offset + 3] = pixel.a;
}

pub fn clear(self: *Frame, color: Color) void {
    var offset: usize = 0;

    while (offset < self.pixels.len) : (offset += 4) {
        self.pixels[offset] = color.r;
        self.pixels[offset + 1] = color.g;
        self.pixels[offset + 2] = color.b;
        self.pixels[offset + 3] = color.a;
    }
}
