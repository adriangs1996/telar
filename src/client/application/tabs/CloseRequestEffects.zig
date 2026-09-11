const TabLocationType = @import("telar-core").TabLocation;
const TabCloseIntent = @import("TabCloseIntent.zig");
const CloseRequestEffects = @This();

context: *anyopaque,
detach: *const fn (*anyopaque, TabLocationType) anyerror!void,
send: *const fn (*anyopaque, TabCloseIntent) anyerror!void,
