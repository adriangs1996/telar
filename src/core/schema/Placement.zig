const id = @import("id.zig");
const PlacementType = @import("../Placement.zig");
const Placement = @This();

pane_id: id.PaneId,
revision: u64,
placement: PlacementType,
