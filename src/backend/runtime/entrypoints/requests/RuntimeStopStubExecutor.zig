const StubExecutor = @This();
const runtime_stop_commands = @import("../../application/commands/runtime_stop.zig");
result: runtime_stop_commands.RuntimeStopResult,
calls: usize = 0,
command: ?runtime_stop_commands.RuntimeStop = null,

pub fn executor(stub: *StubExecutor) runtime_stop_commands.RuntimeStopExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: runtime_stop_commands.RuntimeStop) runtime_stop_commands.RuntimeStopResult {
    const stub: *StubExecutor = @ptrCast(@alignCast(context));
    stub.calls += 1;
    stub.command = command;
    return stub.result;
}
