//! One font span or one procedural grapheme.
text: []const u8,
source: @import("glyph_source.zig").Source,
columns: u32,
/// The face the caller requested; shaping results are keyed by it.
preferred: @import("font_id.zig").Id = .primary,
