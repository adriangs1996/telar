const Effects = @This();
const source_namespace = @import("pane_paste.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, source_namespace.Delivery) anyerror!bool,
