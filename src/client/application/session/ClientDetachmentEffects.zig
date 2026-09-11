const TabLocationType = @import("telar-core").TabLocation;
const Effects = @This();

context: *anyopaque,
detach_tab: *const fn (*anyopaque, TabLocationType) anyerror!void,
