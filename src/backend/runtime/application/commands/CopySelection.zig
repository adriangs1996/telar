const PaneIdType = @import("telar-core").PaneId;
const CopySelection = @This();

pane_id: PaneIdType,
start_x: u16,
start_y: u32,
end_x: u16,
end_y: u32,
linewise: bool,
