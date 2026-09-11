const WorkspaceChange = @This();
const source_namespace = @import("root.zig");
origin: source_namespace.ClientKey,
workspace: source_namespace.schema.WorkspaceLocation,
previous_workspace: ?source_namespace.schema.WorkspaceId = null,
