const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceBookmark = @import("WorkspaceBookmark.zig");
const RemovedWorkspacePanes = @import("RemovedWorkspacePanes.zig");
const WorkspaceDeparture = @This();

source: ?WorkspaceLocationType = null,
bookmark: ?WorkspaceBookmark = null,
panes: RemovedWorkspacePanes = .{},
