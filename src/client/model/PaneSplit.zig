const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const layout_support = @import("../workspace/layout_support.zig");
const RectType = @import("telar-core").Rect;
const PaneSplit = @This();

target_pane: PaneIdType,
location: TabLocationType,
axis: layout_support.Axis,
area: RectType,
