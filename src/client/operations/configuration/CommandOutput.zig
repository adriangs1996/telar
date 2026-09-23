const data = @import("model");
const Output = @import("../../bars/Output.zig");
const CommandOutput = @This();

execution: data.CommandExecution,
command: data.BarCommand,
output: Output,
