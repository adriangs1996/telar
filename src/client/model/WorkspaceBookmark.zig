const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const LayoutType = @import("../workspace/WorkspaceLayout.zig");
const WorkspaceBookmark = @This();

location: TabLocationType,
pane_id: PaneIdType,
tab_layout: LayoutType,
