const Executor = @This();
const Request = @import("TabSnapshotRequest.zig");
const Result = @import("TabSnapshotResult.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, Request) anyerror!Result,

/// Executes the tab-snapshot query through its bound handler.
///
/// ```zig
/// const snapshot = try executor.execute(.{ .location = location });
/// ```
pub fn execute(executor: Executor, request: Request) !Result {
    return executor.execute_fn(executor.context, request);
}
