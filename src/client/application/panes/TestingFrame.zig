const TestingFrame = @This();
const source_namespace = @import("pane_frame.zig");
pane_id: source_namespace.schema.PaneId,
frame_id: u64 = 1,
base_frame_id: u64 = 0,
cells: ?[]const source_namespace.ui.Cell = null,
