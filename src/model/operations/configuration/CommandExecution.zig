const bar_updates = @import("bar_timing.zig");
const CommandTarget = @import("CommandTarget.zig").CommandTarget;
const CommandExecution = @This();

id: bar_updates.CommandExecutionId,
generation: u64,
target: CommandTarget,
