const StubCloseTab = @This();
const close_tab_commands = @import("../../application/commands/close_tab.zig");
const source_namespace = @import("close_tab.zig");
result: ?close_tab_commands.CloseTabResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,

pub fn executor(stub: *StubCloseTab) close_tab_commands.CloseTabExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: close_tab_commands.CloseTab) !close_tab_commands.CloseTabResult {
    const stub: *StubCloseTab = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_location = command.location;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
