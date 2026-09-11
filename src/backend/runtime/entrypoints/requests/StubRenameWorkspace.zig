const StubRenameWorkspace = @This();
const rename_workspace_commands = @import("../../application/commands/rename_workspace.zig");
const source_namespace = @import("rename_workspace.zig");
const std = @import("std");
result: ?rename_workspace_commands.RenameWorkspaceResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?source_namespace.schema.WorkspaceLocation = null,
last_name: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
last_name_len: u8 = 0,

pub fn executor(stub: *StubRenameWorkspace) rename_workspace_commands.RenameWorkspaceExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: rename_workspace_commands.RenameWorkspace) anyerror!rename_workspace_commands.RenameWorkspaceResult {
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
