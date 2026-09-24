const std = @import("std");
const Surface = @This();

pixels: []u8,
width: u32,
height: u32,

pub fn validate(self: Surface) !void {
    const pixel_count = std.math.mul(usize, self.width, self.height) catch
        return error.SurfaceTooLarge;
    const byte_count = std.math.mul(usize, pixel_count, 4) catch
        return error.SurfaceTooLarge;
    if (self.pixels.len != byte_count) {
        return error.InvalidSurface;
    }
}
