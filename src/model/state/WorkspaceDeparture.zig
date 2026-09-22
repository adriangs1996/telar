const core = @import("telar-core");
const WorkspaceBookmark = @import("WorkspaceBookmark.zig");
const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");
const WorkspaceDeparture = @This();

source: ?core.WorkspaceLocation = null,
bookmark: ?WorkspaceBookmark = null,
panes: RemovedWorkspacePanes = .{},
