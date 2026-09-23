const core = @import("telar-core");
const RequestTabMove = @This();

direction: core.TabMoveDirection,
location: ?core.TabLocation = null,
relative_to: ?core.TabId = null,
