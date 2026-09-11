const WorkspaceSnapshotRequest = @import("WorkspaceSnapshotRequest.zig");
const WorkspaceSnapshotResult = @import("WorkspaceSnapshotResult.zig");
const Executor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, WorkspaceSnapshotRequest) anyerror!WorkspaceSnapshotResult,

/// Executes a workspace-snapshot query through its bound handler.
///
/// ```zig
/// const snapshot = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: Executor, request: WorkspaceSnapshotRequest) !WorkspaceSnapshotResult {
    return executor.execute_fn(executor.context, request);
}
