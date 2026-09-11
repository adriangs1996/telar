const Effects = @This();
const source_namespace = @import("pane_closure_delivery.zig");
const core = @import("telar-core");
context: *anyopaque,
ignore_attachment: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
complete_close: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
clear_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
active_geometry_area: *const fn (*anyopaque) core.ui.Rect,
