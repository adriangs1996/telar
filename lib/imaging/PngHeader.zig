//! The validated IHDR: non-interlaced RGB/RGBA at 8 or 16 bits per sample,
//! or an 8-bit palette.
const PngHeader = @This();

pub const ColorType = enum(u8) {
    rgb = 2,
    palette = 3,
    rgba = 6,
};

width: u32,
height: u32,
color: ColorType,
depth: u8 = 8,

/// Bytes per source pixel: the filter distance.
/// Example: `const bpp = header.bytesPerPixel();`
pub fn bytesPerPixel(self: PngHeader) u8 {
    const channels: u8 = switch (self.color) {
        .rgb => 3,
        .palette => 1,
        .rgba => 4,
    };

    return channels * (self.depth / 8);
}

/// Bytes of one unfiltered scanline, without the filter byte.
/// Example: `const stride = header.stride();`
pub fn stride(self: PngHeader) usize {
    return @as(usize, self.width) * self.bytesPerPixel();
}
