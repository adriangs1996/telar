const TabMoveDirectionType = @import("telar-core").TabMoveDirection;
const RequestTabMove = @This();

direction: TabMoveDirectionType,
location: ?@import("telar-core").TabLocation = null,
relative_to: ?@import("telar-core").TabId = null,
