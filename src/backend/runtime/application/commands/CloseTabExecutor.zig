const CloseTabExecutor = @This();
const CloseTab = @import("CloseTab.zig");
const source_namespace = @import("close_tab.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, CloseTab) anyerror!source_namespace.CloseTabResult,

/// Executes tab closure through the bound application handler.
///
/// ```zig
/// const removed = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: CloseTabExecutor, command: CloseTab) !source_namespace.CloseTabResult {
    return executor.execute_fn(executor.context, command);
}
