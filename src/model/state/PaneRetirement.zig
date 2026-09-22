const core = @import("telar-core");
const PaneRetirement = @This();

pane_id: core.PaneId,
location: core.TabLocation,
active: bool,
tab_empty: bool,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
