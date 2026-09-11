const WorkspaceRenamed = @import("../../../workspace/WorkspaceRenamed.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const RenameWorkspaceExecutorType = @import("../../application/commands/RenameWorkspaceExecutor.zig");
const RenameWorkspaceType = @import("../../application/commands/RenameWorkspace.zig");
const std = @import("std");
const StubRenameWorkspace = @This();

result: ?WorkspaceRenamed = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?WorkspaceLocationType = null,
last_name: [max_tab_label_bytes_module]u8 = undefined,
last_name_len: u8 = 0,

pub fn executor(stub: *StubRenameWorkspace) RenameWorkspaceExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: RenameWorkspaceType) anyerror!WorkspaceRenamed {
    const stub: *StubRenameWorkspace = @ptrCast(@alignCast(context));
    std.debug.assert(command.name.len <= stub.last_name.len);

    stub.call_count += 1;
    stub.last_location = command.location;
    stub.last_name_len = @intCast(command.name.len);
    @memcpy(stub.last_name[0..command.name.len], command.name);

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}

pub fn lastName(stub: *const StubRenameWorkspace) []const u8 {
    return stub.last_name[0..stub.last_name_len];
}
