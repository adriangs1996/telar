const StubCreateWorkspace = @This();
const create_workspace_commands = @import("../../application/commands/create_workspace.zig");
const source_namespace = @import("create_workspace.zig");
const std = @import("std");
result: ?create_workspace_commands.CreateWorkspaceResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_size: ?source_namespace.schema.TerminalSize = null,
last_name: [source_namespace.schema.max_workspace_name_bytes]u8 = undefined,
last_name_len: usize = 0,
last_cwd: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_cwd_len: usize = 0,
last_cwd_source: ?source_namespace.schema.PaneId = null,
last_environment_mode: source_namespace.schema.EnvironmentMode = .inherit_runtime,

pub fn executor(stub: *StubCreateWorkspace) create_workspace_commands.CreateWorkspaceExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: create_workspace_commands.CreateWorkspace) !create_workspace_commands.CreateWorkspaceResult {
    const stub: *StubCreateWorkspace = @ptrCast(@alignCast(context));
    std.debug.assert(command.name.len <= stub.last_name.len);
    std.debug.assert(command.launch.cwd.len <= stub.last_cwd.len);

    stub.call_count += 1;
    stub.last_size = command.size;
    stub.last_name_len = command.name.len;
    @memcpy(stub.last_name[0..command.name.len], command.name);
    stub.last_cwd_len = command.launch.cwd.len;
    @memcpy(stub.last_cwd[0..command.launch.cwd.len], command.launch.cwd);
    stub.last_cwd_source = command.launch.cwd_source;
    stub.last_environment_mode = command.launch.environment_mode;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}

pub fn lastName(stub: *const StubCreateWorkspace) []const u8 {
    return stub.last_name[0..stub.last_name_len];
}

pub fn lastCwd(stub: *const StubCreateWorkspace) []const u8 {
    return stub.last_cwd[0..stub.last_cwd_len];
}
