const RuntimeStopExecutor = @This();
const RuntimeStop = @import("RuntimeStop.zig");
const source_namespace = @import("runtime_stop.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, RuntimeStop) source_namespace.RuntimeStopResult,

/// Executes one runtime-stop command through its bound handler.
///
/// ```zig
/// const result = executor.execute(.{ .requester = client });
/// ```
pub fn execute(executor: RuntimeStopExecutor, command: RuntimeStop) source_namespace.RuntimeStopResult {
    return executor.execute_fn(executor.context, command);
}
