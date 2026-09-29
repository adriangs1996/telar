//! One favicon resized to every sprite cell the GUI draws it at: straight
//! RGBA squares, at most `max_side` a side, heap-owned by the worker's
//! allocation and released by whoever consumes the completion.
const FaviconImage = @This();

/// The largest sprite cell the GUI asks for.
pub const max_side: u16 = 96;
/// The sizes the GUI draws a favicon at, one square each: 108 KiB in all.
pub const max_cells = 3;
/// One square side per size, in the GUI's size order.
pub const Sides = [max_cells]u16;

sides: Sides,
pixels: [max_cells][@as(usize, max_side) * max_side * 4]u8 = undefined,

/// The `side * side` RGBA bytes of one size.
/// Example: `const rgba = image.slice(0);`
pub fn slice(self: *const FaviconImage, index: usize) []const u8 {
    return self.pixels[index][0 .. @as(usize, self.sides[index]) * self.sides[index] * 4];
}

pub fn mutableSlice(self: *FaviconImage, index: usize) []u8 {
    return self.pixels[index][0 .. @as(usize, self.sides[index]) * self.sides[index] * 4];
}
