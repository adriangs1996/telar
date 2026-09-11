const freetype = @import("freetype");
const ShapedText = @This();

glyphs: []const freetype.c.hb_glyph_info_t,
positions: []const freetype.c.hb_glyph_position_t,
