const PaneExitEffects = @This();
const source_namespace = @import("close_pane.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, source_namespace.PaneExit) anyerror!void,
