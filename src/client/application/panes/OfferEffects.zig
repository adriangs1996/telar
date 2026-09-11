const PaneResizeType = @import("telar-core").PaneResize;
const PaneBottomReservationType = @import("../../workspace/PaneBottomReservation.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const OfferEffects = @This();

context: *anyopaque,
deliver_resize: *const fn (*anyopaque, PaneResizeType) anyerror!void,
bottom_reservation: *const fn (*anyopaque) ?PaneBottomReservationType = pane_geometry_delivery.noBottomReservation,
