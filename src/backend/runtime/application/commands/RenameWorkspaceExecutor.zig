const RenameWorkspaceExecutor = @This();
const RenameWorkspace = @import("RenameWorkspace.zig");
const source_namespace = @import("rename_workspace.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, RenameWorkspace) anyerror!source_namespace.RenameWorkspaceResult,

/// Executes a workspace rename through the bound application handler.
///
/// ```zig
/// const renamed = try executor.execute(.{ .location = location, .name = "backend" });
/// ```
pub fn execute(executor: RenameWorkspaceExecutor, command: RenameWorkspace) !source_namespace.RenameWorkspaceResult {
    return executor.execute_fn(executor.context, command);
}
