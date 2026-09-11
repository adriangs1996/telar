const TabLocationType = @import("telar-core").TabLocation;
const RenameTab = @This();

location: TabLocationType,
/// Borrowed only for the synchronous transition.
label: []const u8,
