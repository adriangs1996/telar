const core = @import("telar-core");
const RenameWorkspace = @This();

location: core.WorkspaceLocation,
/// Borrowed only for the synchronous `execute` call.
name: []const u8,
