const PaneIdType = @import("telar-core").PaneId;
const StalePaneExit = @This();

pane_id: PaneIdType,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
