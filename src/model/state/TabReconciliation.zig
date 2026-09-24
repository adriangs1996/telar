const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const data = @import("../model.zig");
const TabReconciliation = @This();

location: core.TabLocation,
area: cellgrid.Rect,
removed_panes: data.RemovedPanes = .{},
active: bool,
panes_changed: bool,
snapshot_loaded: bool = false,
layout_revision: u64 = 0,
workspace_revision: u64 = 0,
tabs_revision: u64 = 0,
active_tab_revision: u64 = 0,
panes_revision: u64 = 0,
