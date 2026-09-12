const freetype = @import("freetype");
const ShapedRun = @import("ShapedRun.zig");
const Entry = @This();

pub const max_bytes = 64;
pub const max_glyphs = 32;

text: [max_bytes]u8 = undefined,
len: u8 = 0,
count: u8 = 0,
glyphs: [max_glyphs]freetype.c.hb_glyph_info_t = undefined,
positions: [max_glyphs]freetype.c.hb_glyph_position_t = undefined,

pub fn view(entry: *const Entry) ShapedRun {
    return .{ .glyphs = entry.glyphs[0..entry.count], .positions = entry.positions[0..entry.count] };
}
