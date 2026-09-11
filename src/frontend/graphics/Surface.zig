const std = @import("std");
const Surface = @This();

pixels: []u8,
width: u32,
height: u32,

pub fn validate(surface: Surface) !void {
    const pixel_count = std.math.mul(usize, surface.width, surface.height) catch
        return error.SurfaceTooLarge;
    const byte_count = std.math.mul(usize, pixel_count, 4) catch
        return error.SurfaceTooLarge;
    if (surface.pixels.len != byte_count) {
        return error.InvalidSurface;
    }
}
