const cellgrid = @import("cellgrid");
const layout_support = @import("layout_support.zig");
const SplitGeometry = @This();

area: cellgrid.Rect,
axis: layout_support.Axis,
ratio: u16,
gap: u16,
