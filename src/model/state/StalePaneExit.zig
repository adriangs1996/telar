const core = @import("telar-core");
const StalePaneExit = @This();

pane_id: core.PaneId,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
