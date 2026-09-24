const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const PointerPress = @This();

pane_id: core.PaneId,
position: cellgrid.Point,
now_ns: u64,
