const PaneAttachment = @This();
const pane_mod = @import("../../../pane/root.zig");
context: *anyopaque,
attach: *const fn (*anyopaque, pane_mod.PaneLaunched) anyerror!void,
