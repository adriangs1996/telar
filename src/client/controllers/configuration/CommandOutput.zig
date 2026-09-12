const CommandExecution = @import("CommandExecution.zig");
const CommandType = @import("../../bars/BarCommand.zig");
const OutputType = @import("../../bars/Output.zig");
const CommandOutput = @This();

execution: CommandExecution,
command: CommandType,
output: OutputType,
