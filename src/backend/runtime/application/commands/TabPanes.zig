const TabLocationType = @import("telar-core").TabLocation;
const TabPanes = @This();

context: *anyopaque,
has_running: *const fn (*anyopaque, TabLocationType) bool,
