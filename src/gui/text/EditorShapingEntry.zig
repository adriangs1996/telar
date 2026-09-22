//! One owned long shaping result in the editor's bounded arena.
const font_id = @import("font_id.zig");
hash: u64,
text_start: u16,
text_len: u16,
glyph_start: u16,
glyph_count: u16,
pixel_height: u16,
preferred: font_id.Id,
font: font_id.Id,
columns: u32,
rtl: bool,
