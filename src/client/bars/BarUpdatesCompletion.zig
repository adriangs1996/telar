const data = @import("model");
const OutputType = @import("Output.zig");
/// The result the adapter delivers for one bar command run.
const Completion = @This();

execution_id: data.command_execution.Id,
result: anyerror!OutputType,
