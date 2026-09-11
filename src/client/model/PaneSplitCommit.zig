const PaneSplitCommit = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
area: source_namespace.ui.Rect,
disposition: source_namespace.PaneSplitDisposition,
change: source_namespace.Change,
layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
