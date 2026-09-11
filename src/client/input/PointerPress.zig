const PaneIdType = @import("telar-core").PaneId;
const PointType = @import("telar-core").Point;
const PointerPress = @This();

pane_id: PaneIdType,
position: PointType,
now_ns: u64,
