const cellgrid = @import("cellgrid");
const layout_support = @import("../workspace/layout_support.zig");
const ResizePaneRequest = @This();

direction: layout_support.Direction,
area: cellgrid.Rect,
