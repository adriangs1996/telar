//! Where unfiltered scanlines expand to RGBA and the palette they index.
const PngPalette = @import("PngPalette.zig");

palette: *const PngPalette,
pixels: []u8,
