//! The validated IHDR of a PNG the decoder supports: 8-bit, non-interlaced,
//! RGB, RGBA or palette.
const PngHeader = @This();

pub const ColorType = enum(u8) {
    rgb = 2,
    palette = 3,
    rgba = 6,
};

width: u32,
height: u32,
color: ColorType,

/// Bytes per source pixel: the filter distance.
/// Example: `const bpp = header.bytesPerPixel();`
pub fn bytesPerPixel(header: PngHeader) u8 {
    return switch (header.color) {
        .rgb => 3,
        .palette => 1,
        .rgba => 4,
    };
}

/// Bytes of one unfiltered scanline, without the filter byte.
/// Example: `const stride = header.stride();`
pub fn stride(header: PngHeader) usize {
    return @as(usize, header.width) * header.bytesPerPixel();
}
