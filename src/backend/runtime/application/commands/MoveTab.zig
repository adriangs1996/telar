const core = @import("telar-core");
const MoveTab = @This();

location: core.TabLocation,
direction: core.TabMoveDirection,
relative_to: ?core.TabId = null,
