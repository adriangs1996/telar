const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const layout_support = @import("../workspace/layout_support.zig");
const PaneSplit = @This();

target_pane: core.PaneId,
location: core.TabLocation,
axis: layout_support.Axis,
area: cellgrid.Rect,
