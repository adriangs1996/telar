const StaleTabRemoval = @This();
const source_namespace = @import("types.zig");
location: source_namespace.schema.TabLocation,
absence: source_namespace.TabRemovalAbsence,
workspace_revision: u64,
tabs_revision: u64,
active_tab_revision: u64,
panes_revision: u64,
copy_revision: u64,
