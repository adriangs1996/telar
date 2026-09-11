const WorkspaceReconciliation = @This();
const source_namespace = @import("types.zig");
const RemovedWorkspaceTabs = @import("RemovedWorkspaceTabs.zig");
const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");
previous_active: source_namespace.schema.TabLocation,
active: source_namespace.schema.TabLocation,
removed_tabs: RemovedWorkspaceTabs = .{},
removed_panes: RemovedWorkspacePanes = .{},
workspace_changed: bool = false,
tabs_changed: bool = false,
active_tab_changed: bool = false,
active_snapshot_loaded: bool = false,
workspace_revision: u64 = 0,
tabs_revision: u64 = 0,
active_tab_revision: u64 = 0,
panes_revision: u64 = 0,
