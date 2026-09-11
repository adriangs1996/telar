const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const PaneFrameCommit = @This();

pane_id: PaneIdType,
location: TabLocationType,
frame_id: u64,
graphics_visible: bool,
snapshot: bool,
spans: u64,
cells: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
frame_revision: u64,
