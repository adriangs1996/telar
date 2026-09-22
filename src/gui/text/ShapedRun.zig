//! One shaped face span, borrowed from HarfBuzz or the bounded shaping cache.
const font_id = @import("font_id.zig");
const freetype = @import("freetype");

font: font_id.Id,
columns: u32,
glyphs: []const freetype.c.hb_glyph_info_t,
positions: []const freetype.c.hb_glyph_position_t,
rtl: bool = false,
