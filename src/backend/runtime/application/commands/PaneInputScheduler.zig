const PaneType = @import("../../../pane/Pane.zig");
const Scheduler = @This();

context: *anyopaque,
observation: *const fn (*anyopaque, *PaneType) anyerror!void,
input: *const fn (*anyopaque, *PaneType) anyerror!void,
