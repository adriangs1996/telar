const Completion = @This();
const source_namespace = @import("bar_updates.zig");
const bars = @import("../../../bars/root.zig");
execution_id: source_namespace.CommandExecutionId,
result: anyerror!bars.command.Output,
