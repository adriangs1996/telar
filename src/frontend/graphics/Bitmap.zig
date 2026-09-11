/// A square region of an RGBA pixel store.
const Bitmap = @This();

pixels: []const u8,
/// Row stride of the store, in pixels.
stride: u32,
origin_x: u32 = 0,
origin_y: u32 = 0,
side: u32,

pub fn pixel(bitmap: Bitmap, x: u32, y: u32) [4]u8 {
    const index = (@as(usize, bitmap.origin_y + y) * bitmap.stride + bitmap.origin_x + x) * 4;
    return bitmap.pixels[index..][0..4].*;
}
