const CreateWorkspace = @import("CreateWorkspace.zig");
const CreateWorkspaceResult = @import("CreateWorkspaceResult.zig");
const CreateWorkspaceExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, CreateWorkspace) anyerror!CreateWorkspaceResult,

/// Executes workspace creation through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(command);
/// ```
pub fn execute(executor: CreateWorkspaceExecutor, command: CreateWorkspace) !CreateWorkspaceResult {
    return executor.execute_fn(executor.context, command);
}
