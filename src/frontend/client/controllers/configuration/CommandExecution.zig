const CommandExecution = @This();
const source_namespace = @import("bar_updates.zig");
const bars = @import("../../../bars/root.zig");
id: source_namespace.CommandExecutionId,
generation: u64,
position: bars.Position,
