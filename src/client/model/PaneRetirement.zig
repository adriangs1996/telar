const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const PaneRetirement = @This();

pane_id: PaneIdType,
location: TabLocationType,
active: bool,
tab_empty: bool,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
