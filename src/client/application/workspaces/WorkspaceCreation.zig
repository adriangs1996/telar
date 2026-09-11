const WorkspaceCreation = @This();
const source_namespace = @import("create_workspace.zig");
/// Borrowed only for the synchronous send callback.
name: []const u8,
cwd_source: source_namespace.schema.PaneId,
