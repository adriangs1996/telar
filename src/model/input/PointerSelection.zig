const core = @import("telar-core");
const Point = @import("Point.zig");
const PointerSelection = @This();

start: Point,
end: Point,
granularity: core.Granularity,
cols: u16,
rows: u16,
