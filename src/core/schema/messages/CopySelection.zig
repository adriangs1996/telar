const id = @import("../id.zig");
/// Selection coordinates use the full screen history, not viewport rows.
const CopySelection = @This();

pane_id: id.PaneId,
start_x: u16,
start_y: u32,
end_x: u16,
end_y: u32,
linewise: bool = false,
