const OpenPaneExecutor = @This();
const OpenPane = @import("OpenPane.zig");
const OpenPaneResult = @import("OpenPaneResult.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, OpenPane) anyerror!OpenPaneResult,

/// Executes pane opening through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(command);
/// ```
pub fn execute(executor: OpenPaneExecutor, command: OpenPane) !OpenPaneResult {
    return executor.execute_fn(executor.context, command);
}
