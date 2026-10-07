const cellgrid = @import("cellgrid");
const Point = @import("Point.zig");

start: Point,
end: Point,
granularity: cellgrid.selection.Granularity,
cols: u16,
rows: u16,
