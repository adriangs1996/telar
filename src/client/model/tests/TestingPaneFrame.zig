const PaneIdType = @import("telar-core").PaneId;
const CursorType = @import("telar-core").Cursor;
const InputModesType = @import("telar-core").InputModes;
const ScrollType = @import("telar-core").Scroll;
const CellType = @import("telar-core").Cell;
const TestingPaneFrame = @This();

pane_id: PaneIdType,
frame_id: u64 = 1,
base_frame_id: u64 = 0,
cols: u16 = 2,
rows: u16 = 2,
cursor: CursorType = .{},
input_modes: InputModesType = .{},
scroll: ScrollType = .{ .total_rows = 2, .offset = 0 },
cells: ?[]const CellType = null,
