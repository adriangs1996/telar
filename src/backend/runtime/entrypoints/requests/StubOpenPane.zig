const OpenPaneResultType = @import("../../application/commands/OpenPaneResult.zig");
const OpenPaneType = @import("../../application/commands/OpenPane.zig");
const OpenPaneExecutorType = @import("../../application/commands/OpenPaneExecutor.zig");
const StubOpenPane = @This();

result: ?OpenPaneResultType = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?OpenPaneType = null,

pub fn executor(stub: *StubOpenPane) OpenPaneExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: OpenPaneType) anyerror!OpenPaneResultType {
    const stub: *StubOpenPane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
