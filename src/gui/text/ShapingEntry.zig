const font_id = @import("font_id.zig");
const freetype = @import("freetype");
const ShapedRun = @import("ShapedRun.zig");
const Entry = @This();

pub const max_bytes = 64;
pub const max_glyphs = 32;

text: [max_bytes]u8 = undefined,
len: u8 = 0,
count: u8 = 0,
font: font_id.Id = .primary,
preferred: font_id.Id = .primary,
pixel_height: u16 = 0,
columns: u32 = 0,
rtl: bool = false,
glyphs: [max_glyphs]freetype.c.hb_glyph_info_t = undefined,
positions: [max_glyphs]freetype.c.hb_glyph_position_t = undefined,

pub fn view(self: *const Entry) ShapedRun {
    return .{ .font = self.font, .columns = self.columns, .glyphs = self.glyphs[0..self.count], .positions = self.positions[0..self.count], .rtl = self.rtl };
}
