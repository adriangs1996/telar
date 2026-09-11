const TestingPaneFrame = @This();
const source_namespace = @import("input_and_frames.zig");
pane_id: source_namespace.schema.PaneId,
frame_id: u64 = 1,
base_frame_id: u64 = 0,
cols: u16 = 2,
rows: u16 = 2,
cursor: source_namespace.schema.frame.Cursor = .{},
input_modes: source_namespace.schema.frame.InputModes = .{},
scroll: source_namespace.schema.frame.Scroll = .{ .total_rows = 2, .offset = 0 },
cells: ?[]const source_namespace.ui.Cell = null,
