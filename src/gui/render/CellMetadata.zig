//! Frequently read cell identity and used geometry length, separate from quads.
const Paint = @import("CellPaint.zig");

paint: Paint = undefined,
valid: bool = false,
/// The background quad differs from the theme background and must be drawn.
/// The theme background participates in invalidation, so it stays exact.
background: bool = false,
/// The cursor sat on the cell when its row was last split into shaping
/// runs; a cursor that moves splits the rows it left and entered again.
cursor: bool = false,
/// The cell ended its row segment then; a segment that narrows or widens
/// changes the runs touching its edge.
edge: bool = false,
len: u8 = 0,
