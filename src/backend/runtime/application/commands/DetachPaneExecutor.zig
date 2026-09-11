const DetachPaneExecutor = @This();
const DetachPane = @import("DetachPane.zig");
const source_namespace = @import("detach_pane.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, DetachPane) anyerror!source_namespace.DetachPaneResult,

/// Executes pane detachment through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(executor: DetachPaneExecutor, command: DetachPane) !source_namespace.DetachPaneResult {
    return executor.execute_fn(executor.context, command);
}
