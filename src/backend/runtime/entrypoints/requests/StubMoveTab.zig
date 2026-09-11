const StubMoveTab = @This();
const move_tab_commands = @import("../../application/commands/move_tab.zig");
result: ?move_tab_commands.MoveTabResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?move_tab_commands.MoveTab = null,

pub fn executor(stub: *StubMoveTab) move_tab_commands.MoveTabExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: move_tab_commands.MoveTab) anyerror!move_tab_commands.MoveTabResult {
    const stub: *StubMoveTab = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
