const RenameWorkspace = @This();
const source_namespace = @import("rename_workspace.zig");
location: source_namespace.schema.WorkspaceLocation,
/// Borrowed only for the synchronous `execute` call.
name: []const u8,
