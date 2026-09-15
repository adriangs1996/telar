const TabLocationType = @import("telar-core").TabLocation;
const TabMoveDirectionType = @import("telar-core").TabMoveDirection;
const TabMoveIntent = @This();

location: TabLocationType,
direction: TabMoveDirectionType,
relative_to: ?@import("telar-core").TabId = null,
