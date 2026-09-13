//! One line of text to place: UTF-8 bytes, a baseline origin in device pixels
//! and a color.
const Color = @import("../render/Color.zig");

text: []const u8,
x: f32,
y: f32,
color: Color,
/// Glyph size in device pixels.
pixel_height: u16,
/// One terminal column relative to the baseline, including configured spacing.
/// Fallback ink fits this cell; primary ink preserves the configured font metrics.
cell_bounds: ?@import("../render/Rect.zig") = null,

bold: bool = false,
italic: bool = false,
