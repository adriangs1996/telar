const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Point = @import("Point.zig");
const PointerSelection = @This();

start: Point,
end: Point,
granularity: cellgrid.selection.Granularity,
cols: u16,
rows: u16,
