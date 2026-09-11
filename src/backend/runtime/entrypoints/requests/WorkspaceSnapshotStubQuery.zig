const WorkspaceSnapshotResult = @import("../../application/queries/WorkspaceSnapshotResult.zig");
const WorkspaceSnapshotRequest = @import("../../application/queries/WorkspaceSnapshotRequest.zig");
const WorkspaceSnapshotExecutor = @import("../../application/queries/WorkspaceSnapshotExecutor.zig");
const StubQuery = @This();

result: ?WorkspaceSnapshotResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_request: ?WorkspaceSnapshotRequest = null,

pub fn executor(stub: *StubQuery) WorkspaceSnapshotExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, request: WorkspaceSnapshotRequest) anyerror!WorkspaceSnapshotResult {
    const stub: *StubQuery = @ptrCast(@alignCast(context));
    stub.call_count += 1;
    stub.last_request = request;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}
