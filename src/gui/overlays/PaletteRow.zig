//! What one palette row shows: an icon column, a proportional label, muted
//! secondary text and a right-aligned monospace hint.
const Color = @import("telar-core").Color;

icon: []const u8,
primary: []const u8,
secondary: []const u8 = "",
hint: []const u8 = "",
/// Commands and paths keep the monospace face.
mono: bool = false,
/// Overrides the label color, for failures.
color: ?Color = null,
