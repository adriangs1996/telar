const Header = @This();
const id = @import("id.zig");
const Cursor = @import("Cursor.zig");
const Scroll = @import("Scroll.zig");
pane_id: id.PaneId,
frame_id: u64,
base_frame_id: u64,
cols: u16,
rows: u16,
cursor: Cursor,
scroll: Scroll,
span_count: usize,
