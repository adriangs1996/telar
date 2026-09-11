const Scheduler = @This();
const pane_mod = @import("../../../pane/root.zig");
context: *anyopaque,
observation: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
input: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
