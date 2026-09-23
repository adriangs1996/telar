//! Frequently read cell identity and used geometry length, separate from quads.
const Paint = @import("CellPaint.zig");

paint: Paint = undefined,
valid: bool = false,
len: u8 = 0,
