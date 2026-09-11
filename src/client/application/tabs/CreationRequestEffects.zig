const CreationRequestEffects = @This();
const TabCreationIntent = @import("TabCreationIntent.zig");
context: *anyopaque,
send: *const fn (*anyopaque, TabCreationIntent) anyerror!void,
