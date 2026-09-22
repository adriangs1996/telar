//! A face-local glyph index; its atlas key also includes size and synthetic style.
const font_id = @import("font_id.zig");
font: font_id.Id = .primary,
index: u32 = 0,
