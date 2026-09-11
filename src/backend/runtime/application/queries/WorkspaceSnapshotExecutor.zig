const Executor = @This();
const Request = @import("WorkspaceSnapshotRequest.zig");
const Result = @import("WorkspaceSnapshotResult.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, Request) anyerror!Result,

/// Executes a workspace-snapshot query through its bound handler.
///
/// ```zig
/// const snapshot = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: Executor, request: Request) !Result {
    return executor.execute_fn(executor.context, request);
}
