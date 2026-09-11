const StubOpenPane = @This();
const open_pane_commands = @import("../../application/commands/open_pane.zig");
result: ?open_pane_commands.OpenPaneResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?open_pane_commands.OpenPane = null,

pub fn executor(stub: *StubOpenPane) open_pane_commands.OpenPaneExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: open_pane_commands.OpenPane) anyerror!open_pane_commands.OpenPaneResult {
    const stub: *StubOpenPane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
