const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Effects = @This();

context: *anyopaque,
detach_pane: *const fn (*anyopaque, PaneIdType) anyerror!void,
set_pane_graphics_visible: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
workspace_snapshot_pending: *const fn (*anyopaque) bool,
request_workspace_snapshot: *const fn (*anyopaque, WorkspaceLocationType) anyerror!void,
