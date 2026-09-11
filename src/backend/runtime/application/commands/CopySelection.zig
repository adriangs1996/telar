const CopySelection = @This();
const source_namespace = @import("copy_selection.zig");
pane_id: source_namespace.schema.PaneId,
start_x: u16,
start_y: u32,
end_x: u16,
end_y: u32,
linewise: bool,
