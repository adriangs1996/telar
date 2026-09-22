const data = @import("model");
const bar_update = @import("bar_update.zig");
const Command = @This();

generation: u64,
position: data.bar_values.Position,
result: bar_update.Result,
