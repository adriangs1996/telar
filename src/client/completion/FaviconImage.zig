//! One favicon resized to a sprite cell: straight RGBA, at most `max_side`
//! a side, heap-owned by the worker's allocation and released by whoever
//! consumes the completion.
const FaviconImage = @This();

pub const max_side: u16 = 48;

side: u16,
pixels: [@as(usize, max_side) * max_side * 4]u8 = undefined,

/// The `side * side` RGBA bytes in use.
/// Example: `const rgba = image.slice();`
pub fn slice(image: *const FaviconImage) []const u8 {
    return image.pixels[0 .. @as(usize, image.side) * image.side * 4];
}

pub fn mutableSlice(image: *FaviconImage) []u8 {
    return image.pixels[0 .. @as(usize, image.side) * image.side * 4];
}
