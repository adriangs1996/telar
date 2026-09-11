const types = @import("../../model/types.zig");
const PaneExitEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, types.PaneExit) anyerror!void,
