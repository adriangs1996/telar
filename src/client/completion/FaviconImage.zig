//! One favicon resized to a sprite cell: straight RGBA, at most `max_side`
//! a side, heap-owned by the worker's allocation and released by whoever
//! consumes the completion.
const FaviconImage = @This();

/// The largest sprite cell the GUI asks for: 36 KiB of pixels.
pub const max_side: u16 = 96;

side: u16,
pixels: [@as(usize, max_side) * max_side * 4]u8 = undefined,

/// The `side * side` RGBA bytes in use.
/// Example: `const rgba = image.slice();`
pub fn slice(self: *const FaviconImage) []const u8 {
    return self.pixels[0 .. @as(usize, self.side) * self.side * 4];
}

pub fn mutableSlice(self: *FaviconImage) []u8 {
    return self.pixels[0 .. @as(usize, self.side) * self.side * 4];
}
