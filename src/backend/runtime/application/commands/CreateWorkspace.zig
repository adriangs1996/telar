const core = @import("telar-core");
const CreateWorkspace = @This();

/// Borrowed only for the synchronous `execute` call.
name: []const u8,
size: core.TerminalSize,
/// Every slice in this view is borrowed only for `execute`.
launch: core.LaunchView,
/// The user confirmed creating `launch.cwd` when it does not exist.
create_cwd: bool = false,
