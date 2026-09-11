const StalePaneExit = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
