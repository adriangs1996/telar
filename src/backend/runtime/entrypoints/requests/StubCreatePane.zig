const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const CreatePaneType = @import("../../application/commands/CreatePane.zig");
const CreatePaneExecutorType = @import("../../application/commands/CreatePaneExecutor.zig");
const StubCreatePane = @This();

result: ?PaneLaunchedType = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_command: ?CreatePaneType = null,

pub fn executor(stub: *StubCreatePane) CreatePaneExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: CreatePaneType) anyerror!PaneLaunchedType {
    const stub: *StubCreatePane = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
