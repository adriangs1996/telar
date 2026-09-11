const bar_updates = @import("bar_updates.zig");
const CommandType = @import("telar-client").BarCommand;
const Job = @This();

execution_id: bar_updates.CommandExecutionId,
command: CommandType,
