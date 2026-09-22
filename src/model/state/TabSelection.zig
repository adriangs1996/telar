const core = @import("telar-core");
const TabSelection = @This();

previous: core.TabLocation,
selected: core.TabLocation,
previous_layout_revision: u64,
selected_layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
