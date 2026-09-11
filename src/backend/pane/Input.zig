const Input = @This();
const core = @import("telar-core");
current: []const core.ui.Cell,
acknowledged: []const core.ui.Cell,
cols: u16,
damaged_rows: []const bool,
