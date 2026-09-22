const core = @import("telar-core");
const PointerPress = @This();

pane_id: core.PaneId,
position: core.Point,
now_ns: u64,
