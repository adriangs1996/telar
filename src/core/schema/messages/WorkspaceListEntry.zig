const WorkspaceListEntry = @This();
const source_namespace = @import("workspace.zig");
workspace: source_namespace.WorkspaceId,
name: []const u8,
path: []const u8,
tab_count: u16,
/// Current git branch (or short commit), empty when the workspace is not
/// a repository or has not been probed yet.
branch: []const u8 = "",
dirty: bool = false,
