const core = @import("telar-core");
const WorkspaceLayout = @import("WorkspaceLayout.zig");

location: core.TabLocation,
pane_id: core.PaneId,
workspace_active: bool,
layout: WorkspaceLayout,
