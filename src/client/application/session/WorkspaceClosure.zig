const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceClosure = @This();

workspace: WorkspaceLocationType,
previous_workspace: ?WorkspaceIdType,
