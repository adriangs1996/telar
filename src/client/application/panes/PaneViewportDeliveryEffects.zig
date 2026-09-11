const Effects = @This();
const source_namespace = @import("pane_viewport_delivery.zig");
context: *anyopaque,
set_graphics_visible: *const fn (*anyopaque, source_namespace.schema.PaneId, bool) anyerror!void,
deliver_viewport: *const fn (*anyopaque, source_namespace.schema.SetPaneViewport) anyerror!void,
