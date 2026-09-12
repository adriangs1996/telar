const command_execution = @import("command_execution.zig");
const CommandType = @import("BarCommand.zig");
/// One bar command the adapter runs off the interactive path.
const Job = @This();

execution_id: command_execution.Id,
command: CommandType,
