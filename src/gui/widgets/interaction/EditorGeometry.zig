//! Geometry of one delivered text field. Byte offsets are recomputed from
//! its authoritative field when input arrives; no borrowed text is retained.
id: @import("Id.zig"),
bounds: @import("../../render/Rect.zig"),
columns: u16,
cell_width: f32,
preferred: bool = false,
multiline: bool = false,
line_height: f32 = 1,
font: ?@import("EditorFont.zig") = null,
