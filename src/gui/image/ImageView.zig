//! A borrowed rectangle of straight-alpha RGBA8 pixels inside a larger
//! bitmap: the embedded provider sheet exposes one slot at a time and a
//! decoded PNG exposes itself whole.
const ImageView = @This();

pixels: []const u8,
/// Bytes between the starts of two consecutive rows of the whole bitmap.
stride: u32,
/// Top-left corner of the region inside the bitmap, in pixels.
x: u32 = 0,
y: u32 = 0,
width: u32,
height: u32,

/// The straight RGBA of one region pixel.
/// Example: `const rgba = view.pixel(3, 4);`
pub fn pixel(self: ImageView, column: u32, row: u32) [4]u8 {
    const offset = @as(usize, self.y + row) * self.stride + @as(usize, self.x + column) * 4;
    return self.pixels[offset..][0..4].*;
}
