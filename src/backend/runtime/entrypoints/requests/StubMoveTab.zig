const TabMoved = @import("../../../workspace/TabMoved.zig");
const MoveTabType = @import("../../application/commands/MoveTab.zig");
const MoveTabExecutorType = @import("../../application/commands/MoveTabExecutor.zig");
const StubMoveTab = @This();

result: ?TabMoved = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?MoveTabType = null,

pub fn executor(stub: *StubMoveTab) MoveTabExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: MoveTabType) anyerror!TabMoved {
    const stub: *StubMoveTab = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
