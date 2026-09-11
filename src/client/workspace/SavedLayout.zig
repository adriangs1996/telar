const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const LayoutType = @import("WorkspaceLayout.zig");
const SavedLayout = @This();

location: TabLocationType,
pane_id: PaneIdType,
workspace_active: bool,
layout: LayoutType,
