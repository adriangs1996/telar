const TabLocationType = @import("telar-core").TabLocation;
const LayoutType = @import("../../workspace/WorkspaceLayout.zig");
const Bookmark = @This();

location: TabLocationType,
tab_layout: ?LayoutType,
