const StubExecutor = @This();
const request_graphics_snapshot_commands = @import("../../application/commands/request_graphics_snapshot.zig");
result: request_graphics_snapshot_commands.RequestGraphicsSnapshotResult = .requested,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?request_graphics_snapshot_commands.RequestGraphicsSnapshot = null,

pub fn execute(stub: *StubExecutor, command: request_graphics_snapshot_commands.RequestGraphicsSnapshot) !request_graphics_snapshot_commands.RequestGraphicsSnapshotResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
