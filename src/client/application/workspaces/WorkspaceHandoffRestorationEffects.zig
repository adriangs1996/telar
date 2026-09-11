const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
show_pane_graphics: *const fn (*anyopaque, PaneIdType) anyerror!void,
