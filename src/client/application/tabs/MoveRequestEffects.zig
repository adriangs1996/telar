const MoveRequestEffects = @This();
const TabMoveIntent = @import("TabMoveIntent.zig");
context: *anyopaque,
send: *const fn (*anyopaque, TabMoveIntent) anyerror!void,
