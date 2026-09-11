const ClosePane = @import("ClosePane.zig");
const ClosePaneResult = @import("ClosePaneResult.zig");
const ClosePaneExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, ClosePane) anyerror!ClosePaneResult,

/// Executes a close request through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(executor: ClosePaneExecutor, command: ClosePane) !ClosePaneResult {
    return executor.execute_fn(executor.context, command);
}
