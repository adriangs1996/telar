const TabRemoved = @import("../../../workspace/TabRemoved.zig");
const TabLocationType = @import("telar-core").TabLocation;
const CloseTabExecutorType = @import("../../application/commands/CloseTabExecutor.zig");
const CloseTabType = @import("../../application/commands/CloseTab.zig");
const StubCloseTab = @This();

result: ?TabRemoved = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?TabLocationType = null,

pub fn executor(stub: *StubCloseTab) CloseTabExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: CloseTabType) !TabRemoved {
    const stub: *StubCloseTab = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_location = command.location;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
