const StubExecutor = @This();
const request_snapshot_commands = @import("../../application/commands/request_snapshot.zig");
result: request_snapshot_commands.RequestCellSnapshotResult = .requested,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?request_snapshot_commands.RequestCellSnapshot = null,

pub fn execute(stub: *StubExecutor, command: request_snapshot_commands.RequestCellSnapshot) !request_snapshot_commands.RequestCellSnapshotResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
