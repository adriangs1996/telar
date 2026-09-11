const StubQuery = @This();
const tab_snapshot_query = @import("../../application/queries/tab_snapshot.zig");
result: ?tab_snapshot_query.Result = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_request: ?tab_snapshot_query.Request = null,

pub fn executor(stub: *StubQuery) tab_snapshot_query.Executor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: tab_snapshot_query.Request) anyerror!tab_snapshot_query.Result {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_request = request;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
