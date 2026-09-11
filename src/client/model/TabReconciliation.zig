const TabLocationType = @import("telar-core").TabLocation;
const RectType = @import("telar-core").Rect;
const RemovedPanes = @import("RemovedPanes.zig");
const TabReconciliation = @This();

location: TabLocationType,
area: RectType,
removed_panes: RemovedPanes = .{},
active: bool,
panes_changed: bool,
snapshot_loaded: bool = false,
layout_revision: u64 = 0,
workspace_revision: u64 = 0,
tabs_revision: u64 = 0,
active_tab_revision: u64 = 0,
panes_revision: u64 = 0,
