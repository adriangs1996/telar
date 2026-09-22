const core = @import("telar-core");
const ClientKeyType = @import("../../history/ClientKey.zig");
const GeometryLease = @This();

workspace: core.WorkspaceLocation,
owner: ClientKeyType,
