const PaneIdType = @import("telar-core").PaneId;
const WorkspaceCreation = @This();

/// Borrowed only for the synchronous send callback.
name: []const u8,
/// Explicit launch directory; empty when `cwd_source` supplies it.
cwd: []const u8 = "",
cwd_source: ?PaneIdType,
create_cwd: bool = false,
