const CreatePaneExecutor = @This();
const CreatePane = @import("CreatePane.zig");
const source_namespace = @import("create_pane.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, CreatePane) anyerror!source_namespace.CreatePaneResult,

/// Executes pane creation through the bound application handler.
///
/// ```zig
/// const launched = try executor.execute(command);
/// ```
pub fn execute(executor: CreatePaneExecutor, command: CreatePane) !source_namespace.CreatePaneResult {
    return executor.execute_fn(executor.context, command);
}
