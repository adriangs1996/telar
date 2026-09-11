const WorkspaceList = @This();
const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
revision: u64,
entries: []const WorkspaceListEntry,
