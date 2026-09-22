const core = @import("telar-core");
const RemovedPanes = @import("RemovedPanes.zig");
const TabRemoval = @This();

removed: core.TabLocation,
panes: RemovedPanes,
was_active: bool,
active: ?core.TabLocation,
workspace_removed: bool,
active_layout_revision: u64,
active_tab_revision_before: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
