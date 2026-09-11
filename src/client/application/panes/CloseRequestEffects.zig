const CloseRequestEffects = @This();
const source_namespace = @import("close_pane.zig");
context: *anyopaque,
send: *const fn (*anyopaque, source_namespace.PaneClosure) anyerror!void,
