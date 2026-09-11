const Executor = @This();
const Request = @import("HistoryRequest.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, Request) anyerror!void,

/// Validates, owns, and submits one application-level history request.
///
/// ```zig
/// try executor.execute(request);
/// ```
pub fn execute(executor: Executor, request: Request) !void {
    return executor.execute_fn(executor.context, request);
}
