/// One bar command the adapter runs off the interactive path.
const data = @import("model");
const Job = @This();

execution_id: data.command_execution.Id,
command: data.BarCommand,
