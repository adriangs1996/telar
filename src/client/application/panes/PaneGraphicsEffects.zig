const pane_graphics = @import("pane_graphics.zig");
const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
apply: *const fn (*anyopaque, pane_graphics.Command) anyerror!pane_graphics.ResourceResult,
request_snapshot: *const fn (*anyopaque, PaneIdType) anyerror!void,
disable_shared: *const fn (*anyopaque) anyerror!void,
