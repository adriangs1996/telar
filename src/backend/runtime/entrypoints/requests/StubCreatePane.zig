const StubCreatePane = @This();
const pane_mod = @import("../../../pane/root.zig");
const create_pane_commands = @import("../../application/commands/create_pane.zig");
result: ?pane_mod.PaneLaunched = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?create_pane_commands.CreatePane = null,

pub fn executor(stub: *StubCreatePane) create_pane_commands.CreatePaneExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: create_pane_commands.CreatePane) anyerror!pane_mod.PaneLaunched {
    const stub: *StubCreatePane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
