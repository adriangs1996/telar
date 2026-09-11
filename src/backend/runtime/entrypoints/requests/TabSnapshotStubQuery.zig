const TabSnapshotResult = @import("../../application/queries/TabSnapshotResult.zig");
const TabSnapshotRequest = @import("../../application/queries/TabSnapshotRequest.zig");
const TabSnapshotExecutor = @import("../../application/queries/TabSnapshotExecutor.zig");
const StubQuery = @This();

result: ?TabSnapshotResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_request: ?TabSnapshotRequest = null,

pub fn executor(stub: *StubQuery) TabSnapshotExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: TabSnapshotRequest) anyerror!TabSnapshotResult {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_request = request;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
