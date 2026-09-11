const Effects = @This();
const source_namespace = @import("pane_mouse.zig");
context: *anyopaque,
apply: *const fn (*anyopaque, source_namespace.Effect) anyerror!void,
