const core = @import("telar-core");
const ClientKeyType = @import("../../history/ClientKey.zig");
const WorkspaceChange = @This();

origin: ClientKeyType,
workspace: core.WorkspaceLocation,
previous_workspace: ?core.WorkspaceId = null,
