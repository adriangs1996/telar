const RequestRenameWorkspace = @This();
const source_namespace = @import("rename_workspace.zig");
workspace: source_namespace.schema.WorkspaceLocation,
name: []const u8,
