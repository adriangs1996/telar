const core = @import("telar-core");
const Input = @This();

current: []const core.Cell,
acknowledged: []const core.Cell,
cols: u16,
damaged_rows: []const bool,
