const Effects = @This();
const source_namespace = @import("tab_selection_delivery.zig");
context: *anyopaque,
set_pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
request_tab_snapshot: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
