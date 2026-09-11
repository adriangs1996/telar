const HistoryRequest = @import("HistoryRequest.zig");
const Executor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, HistoryRequest) anyerror!void,

/// Validates, owns, and submits one application-level history request.
///
/// ```zig
/// try executor.execute(request);
/// ```
pub fn execute(executor: Executor, request: HistoryRequest) !void {
    return executor.execute_fn(executor.context, request);
}
