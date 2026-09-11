const PaneProjection = @This();
const source_namespace = @import("multiplexer.zig");
pane_id: source_namespace.schema.PaneId,
cols: u16,
rows: u16,
scroll_offset: u32,
graphics_placeholder: bool,
progress_state: source_namespace.schema.PaneProgressState,
progress_percent: ?u8,
