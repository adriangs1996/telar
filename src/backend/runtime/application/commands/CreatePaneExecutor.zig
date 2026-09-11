const CreatePane = @import("CreatePane.zig");
const PaneLaunched = @import("../../../pane/PaneLaunched.zig");
const CreatePaneExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, CreatePane) anyerror!PaneLaunched,

/// Executes pane creation through the bound application handler.
///
/// ```zig
/// const launched = try executor.execute(command);
/// ```
pub fn execute(executor: CreatePaneExecutor, command: CreatePane) !PaneLaunched {
    return executor.execute_fn(executor.context, command);
}
