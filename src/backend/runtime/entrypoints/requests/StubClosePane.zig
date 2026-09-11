const ClosePaneResultType = @import("../../application/commands/ClosePaneResult.zig");
const ClosePaneType = @import("../../application/commands/ClosePane.zig");
const ClosePaneExecutorType = @import("../../application/commands/ClosePaneExecutor.zig");
const StubClosePane = @This();

result: ClosePaneResultType,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?ClosePaneType = null,

pub fn executor(stub: *StubClosePane) ClosePaneExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: ClosePaneType) anyerror!ClosePaneResultType {
    const stub: *StubClosePane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
