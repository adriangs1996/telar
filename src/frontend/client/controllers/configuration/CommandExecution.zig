const bar_updates = @import("bar_updates.zig");
const PositionType = @import("telar-client").Position;
const CommandExecution = @This();

id: bar_updates.CommandExecutionId,
generation: u64,
position: PositionType,
