//! A single primary-face ASCII glyph as shaping and rasterization resolved
//! it: its atlas slot and HarfBuzz position, without the text or font key.
const GlyphSlot = @import("GlyphSlot.zig");

slot: GlyphSlot,
x_offset: i32,
y_offset: i32,
x_advance: i32,
