const OfferEffects = @This();
const source_namespace = @import("pane_geometry_delivery.zig");
context: *anyopaque,
deliver_resize: *const fn (*anyopaque, source_namespace.schema.PaneResize) anyerror!void,
bottom_reservation: *const fn (*anyopaque) ?source_namespace.layout_mod.PaneBottomReservation = source_namespace.noBottomReservation,
