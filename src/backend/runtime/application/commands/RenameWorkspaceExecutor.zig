const RenameWorkspace = @import("RenameWorkspace.zig");
const WorkspaceRenamed = @import("../../../workspace/WorkspaceRenamed.zig");
const RenameWorkspaceExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, RenameWorkspace) anyerror!WorkspaceRenamed,

/// Executes a workspace rename through the bound application handler.
///
/// ```zig
/// const renamed = try executor.execute(.{ .location = location, .name = "backend" });
/// ```
pub fn execute(executor: RenameWorkspaceExecutor, command: RenameWorkspace) !WorkspaceRenamed {
    return executor.execute_fn(executor.context, command);
}
