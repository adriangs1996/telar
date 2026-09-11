const TabLocationType = @import("telar-core").TabLocation;
const RemovedWorkspaceTabs = @import("RemovedWorkspaceTabs.zig");
const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");
const WorkspaceReconciliation = @This();

previous_active: TabLocationType,
active: TabLocationType,
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
