const TabLocationType = @import("telar-core").TabLocation;
const TabSelection = @This();

previous: TabLocationType,
selected: TabLocationType,
previous_layout_revision: u64,
selected_layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
