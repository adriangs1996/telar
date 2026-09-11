const CreateTabResultType = @import("../../application/commands/CreateTabResult.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const PaneIdType = @import("telar-core").PaneId;
const EnvironmentModeType = @import("telar-core").EnvironmentMode;
const CreateTabExecutorType = @import("../../application/commands/CreateTabExecutor.zig");
const CreateTabType = @import("../../application/commands/CreateTab.zig");
const std = @import("std");
const StubCreateTab = @This();

result: ?CreateTabResultType = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_workspace: ?WorkspaceLocationType = null,
last_size: ?TerminalSizeType = null,
last_label: [max_tab_label_bytes_module]u8 = undefined,
last_label_len: usize = 0,
last_cwd: [max_cwd_bytes_module]u8 = undefined,
last_cwd_len: usize = 0,
last_cwd_source: ?PaneIdType = null,
last_argument_count: u16 = 0,
last_environment_mode: EnvironmentModeType = .inherit_runtime,

pub fn executor(stub: *StubCreateTab) CreateTabExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: CreateTabType) !CreateTabResultType {
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
