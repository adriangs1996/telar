const StubCreateTab = @This();
const create_tab_commands = @import("../../application/commands/create_tab.zig");
const source_namespace = @import("create_tab.zig");
const std = @import("std");
result: ?create_tab_commands.CreateTabResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_workspace: ?source_namespace.schema.WorkspaceLocation = null,
last_size: ?source_namespace.schema.TerminalSize = null,
last_label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
last_label_len: usize = 0,
last_cwd: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_cwd_len: usize = 0,
last_cwd_source: ?source_namespace.schema.PaneId = null,
last_argument_count: u16 = 0,
last_environment_mode: source_namespace.schema.EnvironmentMode = .inherit_runtime,

pub fn executor(stub: *StubCreateTab) create_tab_commands.CreateTabExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: create_tab_commands.CreateTab) !create_tab_commands.CreateTabResult {
    const stub: *StubCreateTab = @ptrCast(@alignCast(context));
    std.debug.assert(command.label.len <= stub.last_label.len);
    std.debug.assert(command.launch.cwd.len <= stub.last_cwd.len);

    stub.call_count += 1;
    stub.last_workspace = command.workspace;
    stub.last_size = command.size;
    stub.last_label_len = command.label.len;
    @memcpy(stub.last_label[0..command.label.len], command.label);
    stub.last_cwd_len = command.launch.cwd.len;
    @memcpy(stub.last_cwd[0..command.launch.cwd.len], command.launch.cwd);
    stub.last_cwd_source = command.launch.cwd_source;
    stub.last_argument_count = command.launch.argument_count;
    stub.last_environment_mode = command.launch.environment_mode;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}

pub fn lastLabel(stub: *const StubCreateTab) []const u8 {
    return stub.last_label[0..stub.last_label_len];
}

pub fn lastCwd(stub: *const StubCreateTab) []const u8 {
    return stub.last_cwd[0..stub.last_cwd_len];
}
