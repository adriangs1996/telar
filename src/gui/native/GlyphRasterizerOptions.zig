//! Mirrors telar_glyph_rasterizer_options. Both byte buffers outlive the rasterizer.
pub const GlyphRasterizerOptions = extern struct {
    font: [*]const u8,
    font_len: usize,
    postscript: ?[*:0]const u8,
    face_index: i32,
    pixels: [*]u8,
    side: u32,
    thicken: u32 = 1,
    strength: u32 = 255,
};
