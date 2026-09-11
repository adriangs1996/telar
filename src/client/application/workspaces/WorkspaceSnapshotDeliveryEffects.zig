const Effects = @This();
const source_namespace = @import("workspace_snapshot_delivery.zig");
context: *anyopaque,
ignore_tab_requests: *const fn (*anyopaque, source_namespace.schema.TabId) void,
clear_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
set_pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
tab_snapshot_pending: *const fn (*anyopaque) bool,
request_tab_snapshot: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
