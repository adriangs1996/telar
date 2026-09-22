const core = @import("telar-core");
const LayoutType = @import("WorkspaceLayout.zig");
const SavedLayout = @This();

location: core.TabLocation,
pane_id: core.PaneId,
workspace_active: bool,
layout: LayoutType,
