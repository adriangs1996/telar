const core = @import("telar-core");
const PaneBottomReservation = @This();

pane_id: core.PaneId,
preferred_height: u16,
minimum_height: u16,
minimum_pane_height: u16,
