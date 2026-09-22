const core = @import("telar-core");
const types = @import("types.zig");
const PaneSplitCommit = @This();

pane_id: core.PaneId,
location: core.TabLocation,
area: core.Rect,
disposition: types.PaneSplitDisposition,
change: types.Change,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
