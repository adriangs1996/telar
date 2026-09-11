const request_snapshot_commands = @import("../../application/commands/request_snapshot.zig");
const RequestCellSnapshotType = @import("../../application/commands/RequestCellSnapshot.zig");
const StubExecutor = @This();

result: request_snapshot_commands.RequestCellSnapshotResult = .requested,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?RequestCellSnapshotType = null,

pub fn execute(stub: *StubExecutor, command: RequestCellSnapshotType) !request_snapshot_commands.RequestCellSnapshotResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
