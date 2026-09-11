const runtime_stop_commands = @import("../../application/commands/runtime_stop.zig");
const RuntimeStopType = @import("../../application/commands/RuntimeStop.zig");
const RuntimeStopExecutorType = @import("../../application/commands/RuntimeStopExecutor.zig");
const StubExecutor = @This();

result: runtime_stop_commands.RuntimeStopResult,
calls: usize = 0,
command: ?RuntimeStopType = null,

pub fn executor(stub: *StubExecutor) RuntimeStopExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: RuntimeStopType) runtime_stop_commands.RuntimeStopResult {
    const stub: *StubExecutor = @ptrCast(@alignCast(context));
    stub.calls += 1;
    stub.command = command;
    return stub.result;
}
