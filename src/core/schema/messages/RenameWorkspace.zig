const RenameWorkspace = @This();
const source_namespace = @import("workspace.zig");
request_id: source_namespace.RequestId,
workspace: source_namespace.WorkspaceLocation,
name: []const u8,
