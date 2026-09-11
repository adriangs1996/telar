const HistoryRequest = @import("../../application/queries/HistoryRequest.zig");
const HistoryExecutor = @import("../../application/queries/HistoryExecutor.zig");
const StubQuery = @This();

failure: ?anyerror = null,
calls: usize = 0,
request: ?HistoryRequest = null,

pub fn executor(stub: *StubQuery) HistoryExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: HistoryRequest) anyerror!void {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.calls += 1;
    stub.request = request;

    if (stub.failure) |failure| {
        return failure;
    }
}
