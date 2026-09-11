const PaneIdType = @import("telar-core").PaneId;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const Effects = @This();

context: *anyopaque,
set_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
deliver_viewport: *const fn (*anyopaque, SetPaneViewportType) anyerror!void,
