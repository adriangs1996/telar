const MoveTabExecutor = @This();
const MoveTab = @import("MoveTab.zig");
const source_namespace = @import("move_tab.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, MoveTab) anyerror!source_namespace.MoveTabResult,

/// Executes a tab move through the bound application handler.
///
/// ```zig
/// const moved = try executor.execute(.{ .location = location, .direction = .next });
/// ```
pub fn execute(executor: MoveTabExecutor, command: MoveTab) !source_namespace.MoveTabResult {
    return executor.execute_fn(executor.context, command);
}
