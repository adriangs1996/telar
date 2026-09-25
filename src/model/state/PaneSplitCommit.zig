const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Change = @import("Change.zig").Change;
const PaneSplitDisposition = @import("PaneSplitDisposition.zig").PaneSplitDisposition;
const PaneSplitCommit = @This();

pane_id: core.PaneId,
location: core.TabLocation,
area: cellgrid.Rect,
disposition: PaneSplitDisposition,
change: Change,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
