const RenameTabExecutor = @This();
const RenameTab = @import("RenameTab.zig");
const source_namespace = @import("rename_tab.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, RenameTab) anyerror!source_namespace.RenameTabResult,

/// Executes a tab rename through the bound application handler.
///
/// ```zig
/// const renamed = try executor.execute(.{ .location = location, .label = "server" });
/// ```
pub fn execute(executor: RenameTabExecutor, command: RenameTab) !source_namespace.RenameTabResult {
    return executor.execute_fn(executor.context, command);
}
