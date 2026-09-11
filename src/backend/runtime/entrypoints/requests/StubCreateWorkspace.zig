const CreateWorkspaceResultType = @import("../../application/commands/CreateWorkspaceResult.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const max_workspace_name_bytes_module = @import("telar-core").max_workspace_name_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const PaneIdType = @import("telar-core").PaneId;
const EnvironmentModeType = @import("telar-core").EnvironmentMode;
const CreateWorkspaceExecutorType = @import("../../application/commands/CreateWorkspaceExecutor.zig");
const CreateWorkspaceType = @import("../../application/commands/CreateWorkspace.zig");
const std = @import("std");
const StubCreateWorkspace = @This();

result: ?CreateWorkspaceResultType = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_size: ?TerminalSizeType = null,
last_name: [max_workspace_name_bytes_module]u8 = undefined,
last_name_len: usize = 0,
last_cwd: [max_cwd_bytes_module]u8 = undefined,
last_cwd_len: usize = 0,
last_cwd_source: ?PaneIdType = null,
last_environment_mode: EnvironmentModeType = .inherit_runtime,

pub fn executor(stub: *StubCreateWorkspace) CreateWorkspaceExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: CreateWorkspaceType) !CreateWorkspaceResultType {
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
