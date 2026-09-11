const RectType = @import("telar-core").Rect;
const PaneResizeType = @import("telar-core").PaneResize;
const PaneBottomReservationType = @import("../../workspace/PaneBottomReservation.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const Effects = @This();

context: *anyopaque,
invalidate_graphics_placements: *const fn (*anyopaque) void,
request_visible_attachments: *const fn (*anyopaque, RectType) anyerror!void,
deliver_resize: *const fn (*anyopaque, PaneResizeType) anyerror!void,
bottom_reservation: *const fn (*anyopaque) ?PaneBottomReservationType = pane_geometry_delivery.noBottomReservation,
