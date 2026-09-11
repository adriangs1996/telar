const Effects = @This();
const source_namespace = @import("pane_frame_delivery.zig");
context: *anyopaque,
pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
set_pane_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
