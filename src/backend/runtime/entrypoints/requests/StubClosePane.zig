const StubClosePane = @This();
const close_pane_commands = @import("../../application/commands/close_pane.zig");
result: close_pane_commands.ClosePaneResult,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?close_pane_commands.ClosePane = null,

pub fn executor(stub: *StubClosePane) close_pane_commands.ClosePaneExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: close_pane_commands.ClosePane) anyerror!close_pane_commands.ClosePaneResult {
    const stub: *StubClosePane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
