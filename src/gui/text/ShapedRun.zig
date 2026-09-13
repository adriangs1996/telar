//! One shaped face span, borrowed from HarfBuzz or the bounded shaping cache.
const freetype = @import("freetype");

font: @import("font_id.zig").Id,
columns: u32,
glyphs: []const freetype.c.hb_glyph_info_t,
positions: []const freetype.c.hb_glyph_position_t,
