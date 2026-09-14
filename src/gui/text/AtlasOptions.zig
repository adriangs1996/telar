//! How a glyph atlas is opened: the face bytes and the first size to
//! rasterize at. Runs may ask for other sizes later.
const std = @import("std");

font: []const u8,
pixel_height: u16,
face_index: i32 = 0,
postscript: []const u8 = "",
thicken: bool = false,
thicken_strength: u8 = 255,
/// Reads discovered fallback font files; without it the set never looks
/// for installed faces and uncovered graphemes keep the replacement glyph.
io: ?std.Io = null,
