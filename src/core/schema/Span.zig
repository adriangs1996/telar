const CellType = @import("../ui/Cell.zig");
const Span = @This();

start: u32,
cells: []const CellType,
