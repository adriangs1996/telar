const ClosePaneResult = @This();
const source_namespace = @import("close_pane.zig");
pane_id: source_namespace.schema.PaneId,
newly_requested: bool,
