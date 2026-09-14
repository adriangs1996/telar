//! What identifies a shaping result: the UTF-8 bytes and the face they were
//! requested for. Equal text in two faces never shares glyphs or advances.
text: []const u8,
face: @import("font_id.zig").Id = .primary,
