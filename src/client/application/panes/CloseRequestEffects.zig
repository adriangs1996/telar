const PaneClosureType = @import("../../model/PaneClosure.zig");
const CloseRequestEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, PaneClosureType) anyerror!void,
