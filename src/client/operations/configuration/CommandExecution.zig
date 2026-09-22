const model = @import("../../bars/model.zig");
const bar_updates = @import("bar_updates.zig");
const CommandExecution = @This();

id: bar_updates.CommandExecutionId,
generation: u64,
position: model.Position,
