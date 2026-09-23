const core = @import("telar-core");
const RequestRenameWorkspace = @This();

workspace: core.WorkspaceLocation,
name: []const u8,
