const core = @import("telar-core");
const RowSync = @This();

source: []const core.Cell,
reference: []const core.Cell,
start: u16,
end: u16,
