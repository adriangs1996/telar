const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const TabCreation = @This();

previous: TabLocationType,
created: TabLocationType,
created_root_pane_id: PaneIdType,
created_position: u16,
previous_layout_revision: u64,
created_layout_revision: u64,
tabs_revision_before: u64,
active_tab_revision_before: u64,
copy_revision_before: u64,
copy_released: bool,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
