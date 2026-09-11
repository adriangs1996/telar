const TabLocationType = @import("telar-core").TabLocation;
const TabRenameIntent = @This();

location: TabLocationType,
/// Borrowed only for the synchronous send callback.
label: []const u8,
