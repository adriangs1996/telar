const TabCreationIntent = @import("TabCreationIntent.zig");
const CreationRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, TabCreationIntent) anyerror!void,
