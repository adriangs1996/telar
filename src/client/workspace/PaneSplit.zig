const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const layout_mod = @import("layout_support.zig");
const RectType = @import("telar-core").Rect;
const PaneSplit = @This();

existing_pane: PaneIdType,
new_pane: PaneIdType,
location: TabLocationType,
axis: layout_mod.Axis,
area: RectType,
