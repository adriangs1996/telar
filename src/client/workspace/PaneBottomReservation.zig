const PaneBottomReservation = @This();
const source_namespace = @import("layout_support.zig");
pane_id: source_namespace.schema.PaneId,
preferred_height: u16,
minimum_height: u16,
minimum_pane_height: u16,
