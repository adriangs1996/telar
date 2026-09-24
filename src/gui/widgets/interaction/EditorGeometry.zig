//! Geometry of one delivered text field. Byte offsets are recomputed from
//! its authoritative field when input arrives; no borrowed text is retained.
const Id = @import("Id.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const EditorFont = @import("EditorFont.zig");

id: Id,
bounds: Rect,
columns: u16,
cell_width: f32,
preferred: bool = false,
multiline: bool = false,
line_height: f32 = 1,
font: ?EditorFont = null,
