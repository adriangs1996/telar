const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const LayoutType = @import("WorkspaceLayout.zig");
const Bookmark = @This();

location: TabLocationType,
pane_id: PaneIdType,
tab_layout: ?LayoutType = null,
