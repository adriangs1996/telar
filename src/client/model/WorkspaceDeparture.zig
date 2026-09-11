const WorkspaceDeparture = @This();
const source_namespace = @import("types.zig");
const WorkspaceBookmark = @import("WorkspaceBookmark.zig");
const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");
source: ?source_namespace.schema.WorkspaceLocation = null,
bookmark: ?WorkspaceBookmark = null,
panes: RemovedWorkspacePanes = .{},
