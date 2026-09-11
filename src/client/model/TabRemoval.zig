const TabRemoval = @This();
const source_namespace = @import("types.zig");
const RemovedPanes = @import("RemovedPanes.zig");
removed: source_namespace.schema.TabLocation,
panes: RemovedPanes,
was_active: bool,
active: ?source_namespace.schema.TabLocation,
workspace_removed: bool,
active_layout_revision: u64,
active_tab_revision_before: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
