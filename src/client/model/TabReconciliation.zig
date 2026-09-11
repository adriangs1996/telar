const TabReconciliation = @This();
const source_namespace = @import("types.zig");
const RemovedPanes = @import("RemovedPanes.zig");
location: source_namespace.schema.TabLocation,
area: source_namespace.ui.Rect,
removed_panes: RemovedPanes = .{},
active: bool,
panes_changed: bool,
snapshot_loaded: bool = false,
layout_revision: u64 = 0,
workspace_revision: u64 = 0,
tabs_revision: u64 = 0,
active_tab_revision: u64 = 0,
panes_revision: u64 = 0,
