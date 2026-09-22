const core = @import("telar-core");
const TabMoveIntent = @This();

location: core.TabLocation,
direction: core.TabMoveDirection,
relative_to: ?core.TabId = null,
