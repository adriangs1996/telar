const CopyModeFrame = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
previous_offset: u32,
scroll: source_namespace.schema.frame.Scroll,
