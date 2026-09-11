const TabMoveIntent = @import("TabMoveIntent.zig");
const MoveRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, TabMoveIntent) anyerror!void,
