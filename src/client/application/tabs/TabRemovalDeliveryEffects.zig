const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Effects = @This();

context: *anyopaque,
retire_tab_requests: *const fn (*anyopaque, TabLocationType) void,
clear_pane_graphics: *const fn (*anyopaque, PaneIdType) void,
set_pane_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
tab_snapshot_pending: *const fn (*anyopaque) bool,
request_tab_snapshot: *const fn (*anyopaque, TabLocationType) anyerror!void,
forget_workspace: *const fn (*anyopaque, WorkspaceLocationType) void,
request_workspace: *const fn (*anyopaque, WorkspaceIdType) anyerror!void,
