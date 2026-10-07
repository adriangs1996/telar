const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const layout = @import("../workspace/layout_support.zig");

target_pane: core.PaneId,
location: core.TabLocation,
axis: layout.Axis,
area: cellgrid.Rect,
