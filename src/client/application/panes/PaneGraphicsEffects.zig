const Effects = @This();
const source_namespace = @import("pane_graphics.zig");
context: *anyopaque,
apply: *const fn (*anyopaque, source_namespace.Command) anyerror!source_namespace.ResourceResult,
request_snapshot: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
disable_shared: *const fn (*anyopaque) anyerror!void,
