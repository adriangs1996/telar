const CellType = @import("telar-core").Cell;
const Input = @This();

current: []const CellType,
acknowledged: []const CellType,
cols: u16,
damaged_rows: []const bool,
