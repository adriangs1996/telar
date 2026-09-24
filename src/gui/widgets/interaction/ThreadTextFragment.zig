//! Delivered hit geometry owns only coordinates and offsets, never source bytes.
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;

row: u16,
section: @FieldType(MessageLayoutOwner, "section"),
offset: u32,
len: u32,
bounds: Rect,
clip: Rect,
caret_start: u16,
caret_count: u16,
