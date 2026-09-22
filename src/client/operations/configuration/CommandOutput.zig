const data = @import("model");
const OutputType = @import("../../bars/Output.zig");
const CommandOutput = @This();

execution: data.CommandExecution,
command: data.BarCommand,
output: OutputType,
