const Point = @import("Point.zig");
const GranularityType = @import("telar-core").Granularity;
const PointerSelection = @This();

start: Point,
end: Point,
granularity: GranularityType,
cols: u16,
rows: u16,
