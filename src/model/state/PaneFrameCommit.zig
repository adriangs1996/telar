const core = @import("telar-core");
const PaneFrameCommit = @This();

pane_id: core.PaneId,
location: core.TabLocation,
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
