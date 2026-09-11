const CommandOutput = @This();
const CommandExecution = @import("CommandExecution.zig");
const bars = @import("../../../bars/root.zig");
execution: CommandExecution,
command: bars.Command,
output: bars.command.Output,
