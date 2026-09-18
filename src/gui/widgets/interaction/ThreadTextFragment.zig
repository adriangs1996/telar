//! Delivered hit geometry owns only coordinates and offsets, never source bytes.
row: u16,
section: @FieldType(@import("../MessageLayoutOwner.zig"), "section"),
offset: u32,
len: u32,
bounds: @import("../../render/Rect.zig"),
clip: @import("../../render/Rect.zig"),
caret_start: u16,
caret_count: u16,
