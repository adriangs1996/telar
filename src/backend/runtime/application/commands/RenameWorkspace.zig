const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RenameWorkspace = @This();

location: WorkspaceLocationType,
/// Borrowed only for the synchronous `execute` call.
name: []const u8,
