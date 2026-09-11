const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const ClientKeyType = @import("../../history/ClientKey.zig");
const GeometryLease = @This();

workspace: WorkspaceLocationType,
owner: ClientKeyType,
