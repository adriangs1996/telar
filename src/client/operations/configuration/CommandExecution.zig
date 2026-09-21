const bar_updates = @import("bar_updates.zig");
const PositionType = @import("../../bars/model.zig").Position;
const CommandExecution = @This();

id: bar_updates.CommandExecutionId,
generation: u64,
position: PositionType,
