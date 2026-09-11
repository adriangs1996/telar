const CommandExecution = @import("CommandExecution.zig");
const CommandType = @import("telar-client").BarCommand;
const OutputType = @import("../../../bars/Output.zig");
const CommandOutput = @This();

execution: CommandExecution,
command: CommandType,
output: OutputType,
