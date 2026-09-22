//! What identifies a shaping result: the UTF-8 bytes, the face they were
//! requested for and the pixel height they were shaped at. Equal text in
//! two faces or at two heights never shares glyphs or advances.
const font_id = @import("font_id.zig");
text: []const u8,
face: font_id.Id = .primary,
pixel_height: u16 = 0,
