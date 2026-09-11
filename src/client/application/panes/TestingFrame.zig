const PaneIdType = @import("telar-core").PaneId;
const CellType = @import("telar-core").Cell;
const TestingFrame = @This();

pane_id: PaneIdType,
frame_id: u64 = 1,
base_frame_id: u64 = 0,
cells: ?[]const CellType = null,
