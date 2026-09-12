const command_execution = @import("command_execution.zig");
const OutputType = @import("Output.zig");
/// The result the adapter delivers for one bar command run.
const Completion = @This();

execution_id: command_execution.Id,
result: anyerror!OutputType,
