const TabLocationType = @import("telar-core").TabLocation;
const Effects = @This();

context: *anyopaque,
pending: *const fn (*anyopaque) bool,
request: *const fn (*anyopaque, TabLocationType) anyerror!void,
