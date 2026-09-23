const RequestWorkspaceCreation = @This();

/// Borrowed only for the synchronous request.
name: []const u8,
/// Expanded absolute directory typed in the new-context form; empty
/// inherits the focused pane's directory through `cwd_source`.
cwd: []const u8 = "",
/// The user confirmed creating `cwd` when it does not exist.
create_cwd: bool = false,
