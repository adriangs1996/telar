const StubQuery = @This();
const workspace_snapshot_query = @import("../../application/queries/workspace_snapshot.zig");
result: ?workspace_snapshot_query.Result = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_request: ?workspace_snapshot_query.Request = null,

pub fn executor(stub: *StubQuery) workspace_snapshot_query.Executor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: workspace_snapshot_query.Request) anyerror!workspace_snapshot_query.Result {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_request = request;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
