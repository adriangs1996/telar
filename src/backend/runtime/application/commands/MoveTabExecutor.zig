const MoveTab = @import("MoveTab.zig");
const TabMoved = @import("../../../workspace/TabMoved.zig");
const MoveTabExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, MoveTab) anyerror!TabMoved,

/// Executes a tab move through the bound application handler.
///
/// ```zig
/// const moved = try executor.execute(.{ .location = location, .direction = .next });
/// ```
pub fn execute(executor: MoveTabExecutor, command: MoveTab) !TabMoved {
    return executor.execute_fn(executor.context, command);
}
