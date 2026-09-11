const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const layout = @import("../workspace/layout_support.zig");
const RectType = @import("telar-core").Rect;
const Split = @This();

target_pane: PaneIdType,
location: TabLocationType,
axis: layout.Axis,
area: RectType,
