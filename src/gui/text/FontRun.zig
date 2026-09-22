//! One font span or one procedural grapheme.
const glyph_source = @import("glyph_source.zig");
const font_id = @import("font_id.zig");
text: []const u8,
source: glyph_source.Source,
columns: u32,
/// The face the caller requested; shaping results are keyed by it.
preferred: font_id.Id = .primary,
