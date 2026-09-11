const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
const WorkspaceList = @This();

revision: u64,
entries: []const WorkspaceListEntry,
