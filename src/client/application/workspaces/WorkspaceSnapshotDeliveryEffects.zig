const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const Effects = @This();

context: *anyopaque,
ignore_tab_requests: *const fn (*anyopaque, TabIdType) void,
clear_pane_graphics: *const fn (*anyopaque, PaneIdType) void,
set_pane_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
tab_snapshot_pending: *const fn (*anyopaque) bool,
request_tab_snapshot: *const fn (*anyopaque, TabLocationType) anyerror!void,
