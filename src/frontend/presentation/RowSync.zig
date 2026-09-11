const CellType = @import("telar-core").Cell;
const RowSync = @This();

source: []const CellType,
reference: []const CellType,
start: u16,
end: u16,
