const WorkspaceClosure = @This();
const source_namespace = @import("resync_required.zig");
workspace: source_namespace.schema.WorkspaceLocation,
previous_workspace: ?source_namespace.schema.WorkspaceId,
