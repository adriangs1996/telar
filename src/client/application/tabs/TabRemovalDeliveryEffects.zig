const Effects = @This();
const source_namespace = @import("tab_removal_delivery.zig");
context: *anyopaque,
retire_tab_requests: *const fn (*anyopaque, source_namespace.schema.TabLocation) void,
clear_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
set_pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
tab_snapshot_pending: *const fn (*anyopaque) bool,
request_tab_snapshot: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
forget_workspace: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) void,
request_workspace: *const fn (*anyopaque, source_namespace.schema.WorkspaceId) anyerror!void,
