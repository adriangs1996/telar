const TabSelection = @This();
const source_namespace = @import("types.zig");
previous: source_namespace.schema.TabLocation,
selected: source_namespace.schema.TabLocation,
previous_layout_revision: u64,
selected_layout_revision: u64,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
