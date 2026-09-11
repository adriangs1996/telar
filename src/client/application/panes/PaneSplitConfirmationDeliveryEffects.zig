const Effects = @This();
const source_namespace = @import("pane_split_confirmation_delivery.zig");
context: *anyopaque,
detach_pane: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
set_pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
workspace_snapshot_pending: *const fn (*anyopaque) bool,
request_workspace_snapshot: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) anyerror!void,
