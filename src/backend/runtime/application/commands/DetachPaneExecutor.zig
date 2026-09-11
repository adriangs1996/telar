const DetachPane = @import("DetachPane.zig");
const detach_pane = @import("detach_pane.zig");
const DetachPaneExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, DetachPane) anyerror!detach_pane.DetachPaneResult,

/// Executes pane detachment through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(executor: DetachPaneExecutor, command: DetachPane) !detach_pane.DetachPaneResult {
    return executor.execute_fn(executor.context, command);
}
