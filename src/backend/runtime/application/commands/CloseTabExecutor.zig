const CloseTab = @import("CloseTab.zig");
const TabRemoved = @import("../../../workspace/TabRemoved.zig");
const CloseTabExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, CloseTab) anyerror!TabRemoved,

/// Executes tab closure through the bound application handler.
///
/// ```zig
/// const removed = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: CloseTabExecutor, command: CloseTab) !TabRemoved {
    return executor.execute_fn(executor.context, command);
}
