const ClientKeyType = @import("../../history/ClientKey.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceChange = @This();

origin: ClientKeyType,
workspace: WorkspaceLocationType,
previous_workspace: ?WorkspaceIdType = null,
