const core = @import("telar-core");
/// Committed position of a tab after a move request.
const TabMoved = @This();

location: core.TabLocation,
position: u16,
