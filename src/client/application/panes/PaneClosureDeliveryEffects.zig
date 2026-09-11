const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const Effects = @This();

context: *anyopaque,
ignore_attachment: *const fn (*anyopaque, PaneIdType) void,
complete_close: *const fn (*anyopaque, PaneIdType) void,
clear_pane_graphics: *const fn (*anyopaque, PaneIdType) void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
active_geometry_area: *const fn (*anyopaque) RectType,
