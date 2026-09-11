const StubQuery = @This();
const history_query = @import("../../application/queries/history.zig");
failure: ?anyerror = null,
calls: usize = 0,
request: ?history_query.Request = null,

pub fn executor(stub: *StubQuery) history_query.Executor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: history_query.Request) anyerror!void {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.calls += 1;
    stub.request = request;

    if (stub.failure) |failure| {
        return failure;
    }
}
