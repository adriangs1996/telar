const model = @import("../../bars/model.zig");
const bar_update = @import("bar_update.zig");
const Command = @This();

generation: u64,
position: model.Position,
result: bar_update.Result,
