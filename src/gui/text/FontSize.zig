//! One sized instance of a face: the FreeType `FT_Size` for one pixel
//! height. Its metrics stay readable while another size is active.
const freetype = @import("freetype");
const FontSize = @This();

pixel_height: u16,
handle: freetype.c.FT_Size,

/// Distance from the baseline to the top of the tallest glyph, in pixels.
/// Example: `const top = size.ascender();`
pub fn ascender(size: FontSize) i32 {
    return round26(size.handle.*.metrics.ascender);
}

/// The natural line box height, in pixels, never below one.
/// Example: `const line = size.lineHeight();`
pub fn lineHeight(size: FontSize) u32 {
    return @intCast(@max(1, round26(size.handle.*.metrics.height)));
}

/// The widest advance, in pixels, never below one.
/// Example: `const cell = size.maxAdvance();`
pub fn maxAdvance(size: FontSize) u16 {
    return @intCast(@max(1, round26(size.handle.*.metrics.max_advance)));
}

/// Rounds a 26.6 fixed-point value to the nearest pixel.
/// Example: `const pixels = FontSize.round26(position.x_advance);`
pub fn round26(value: anytype) i32 {
    const signed: i64 = @intCast(value);
    return @intCast(if (signed >= 0) (signed + 32) >> 6 else -(((-signed) + 32) >> 6));
}
