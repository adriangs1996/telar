const TabSnapshotRequest = @import("TabSnapshotRequest.zig");
const TabSnapshotResult = @import("TabSnapshotResult.zig");
const Executor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, TabSnapshotRequest) anyerror!TabSnapshotResult,

/// Executes the tab-snapshot query through its bound handler.
///
/// ```zig
/// const snapshot = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: Executor, request: TabSnapshotRequest) !TabSnapshotResult {
    return executor.execute_fn(executor.context, request);
}
