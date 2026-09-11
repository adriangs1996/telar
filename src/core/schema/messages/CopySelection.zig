/// Selection coordinates use the full screen history, not viewport rows.
const CopySelection = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
start_x: u16,
start_y: u32,
end_x: u16,
end_y: u32,
linewise: bool = false,
