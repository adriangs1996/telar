const PaneRetirement = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
active: bool,
tab_empty: bool,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
