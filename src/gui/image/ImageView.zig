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
pub fn pixel(view: ImageView, column: u32, row: u32) [4]u8 {
    const offset = @as(usize, view.y + row) * view.stride + @as(usize, view.x + column) * 4;
    return view.pixels[offset..][0..4].*;
}
