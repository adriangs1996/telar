const TabLocationType = @import("telar-core").TabLocation;
const LayoutType = @import("WorkspaceLayout.zig");
const PendingLayoutRestore = @This();

location: TabLocationType,
layout: LayoutType,
restore_saved_focus: bool = false,
