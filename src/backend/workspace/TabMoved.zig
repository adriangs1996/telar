const TabLocationType = @import("telar-core").TabLocation;
/// Committed position of a tab after a move request.
const TabMoved = @This();

location: TabLocationType,
position: u16,
