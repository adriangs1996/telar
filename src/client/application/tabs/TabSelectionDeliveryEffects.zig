const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const Effects = @This();

context: *anyopaque,
set_pane_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
request_tab_snapshot: *const fn (*anyopaque, TabLocationType) anyerror!void,
