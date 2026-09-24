const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const TestingPaneFrame = @This();

pane_id: core.PaneId,
frame_id: u64 = 1,
base_frame_id: u64 = 0,
cols: u16 = 2,
rows: u16 = 2,
cursor: core.Cursor = .{},
input_modes: keyinput.InputModes = .{},
scroll: core.Scroll = .{ .total_rows = 2, .offset = 0 },
cells: ?[]const cellgrid.Cell = null,
