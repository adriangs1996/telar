const RequestedRename = @This();
const source_namespace = @import("rename_workspace.zig");
workspace: source_namespace.schema.WorkspaceLocation,
/// Borrowed only for the synchronous send callback.
name: []const u8,
