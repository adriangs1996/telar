const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const RectType = @import("telar-core").Rect;
const types = @import("types.zig");
const PaneSplitCommit = @This();

pane_id: PaneIdType,
location: TabLocationType,
area: RectType,
disposition: types.PaneSplitDisposition,
change: types.Change,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
