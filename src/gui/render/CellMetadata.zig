//! Frequently read cell identity and used geometry length, separate from quads.
const Paint = @import("CellPaint.zig");

paint: Paint = undefined,
valid: bool = false,
/// The background quad differs from the theme background and must be drawn.
/// The theme background participates in invalidation, so it stays exact.
background: bool = false,
len: u8 = 0,
