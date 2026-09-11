const RenameTab = @import("RenameTab.zig");
const TabRenamed = @import("../../../workspace/TabRenamed.zig");
const RenameTabExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, RenameTab) anyerror!TabRenamed,

/// Executes a tab rename through the bound application handler.
///
/// ```zig
/// const renamed = try executor.execute(.{ .location = location, .label = "server" });
/// ```
pub fn execute(executor: RenameTabExecutor, command: RenameTab) !TabRenamed {
    return executor.execute_fn(executor.context, command);
}
