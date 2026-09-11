const PointerSelection = @This();
const Point = @import("Point.zig");
const core = @import("telar-core");
start: Point,
end: Point,
granularity: core.select.Granularity,
cols: u16,
rows: u16,
