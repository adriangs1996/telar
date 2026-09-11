const bar_updates = @import("bar_updates.zig");
const OutputType = @import("../../../bars/Output.zig");
const Completion = @This();

execution_id: bar_updates.CommandExecutionId,
result: anyerror!OutputType,
