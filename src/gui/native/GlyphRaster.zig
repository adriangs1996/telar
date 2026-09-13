//! A measured glyph and its reserved atlas rectangle. Mirrors telar_glyph_raster.
pub const GlyphRaster = extern struct {
    index: u32,
    style: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,
};
