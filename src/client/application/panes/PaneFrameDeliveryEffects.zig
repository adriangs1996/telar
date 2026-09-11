const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
pane_graphics_visible: *const fn (*anyopaque, PaneIdType) bool,
set_pane_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
