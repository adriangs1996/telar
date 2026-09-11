const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RequestedRename = @This();

workspace: WorkspaceLocationType,
/// Borrowed only for the synchronous send callback.
name: []const u8,
