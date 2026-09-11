const PaneIdType = @import("telar-core").PaneId;
const PaneBottomReservation = @This();

pane_id: PaneIdType,
preferred_height: u16,
minimum_height: u16,
minimum_pane_height: u16,
