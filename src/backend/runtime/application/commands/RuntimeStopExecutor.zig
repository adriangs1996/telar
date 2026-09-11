const RuntimeStop = @import("RuntimeStop.zig");
const runtime_stop = @import("runtime_stop.zig");
const RuntimeStopExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, RuntimeStop) runtime_stop.RuntimeStopResult,

/// Executes one runtime-stop command through its bound handler.
///
/// ```zig
/// const result = executor.execute(.{ .requester = client });
/// ```
pub fn execute(executor: RuntimeStopExecutor, command: RuntimeStop) runtime_stop.RuntimeStopResult {
    return executor.execute_fn(executor.context, command);
}
