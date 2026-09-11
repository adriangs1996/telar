const Effects = @This();
const source_namespace = @import("pane_geometry_delivery.zig");
context: *anyopaque,
invalidate_graphics_placements: *const fn (*anyopaque) void,
request_visible_attachments: *const fn (*anyopaque, source_namespace.ui.Rect) anyerror!void,
deliver_resize: *const fn (*anyopaque, source_namespace.schema.PaneResize) anyerror!void,
bottom_reservation: *const fn (*anyopaque) ?source_namespace.layout_mod.PaneBottomReservation = source_namespace.noBottomReservation,
