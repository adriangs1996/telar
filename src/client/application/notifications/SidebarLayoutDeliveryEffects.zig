const Effects = @This();
const source_namespace = @import("sidebar_layout_delivery.zig");
context: *anyopaque,
project_view: *const fn (*anyopaque, bool, u16) void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque, *source_namespace.multiplexer.Model) anyerror!void,
