//! HarfBuzz's view of one shaped line, borrowed from the shaping buffer
//! until the next shape call.
const freetype = @import("freetype");

glyphs: []const freetype.c.hb_glyph_info_t,
positions: []const freetype.c.hb_glyph_position_t,
