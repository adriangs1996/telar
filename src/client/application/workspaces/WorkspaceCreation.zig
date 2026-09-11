const PaneIdType = @import("telar-core").PaneId;
const WorkspaceCreation = @This();

/// Borrowed only for the synchronous send callback.
name: []const u8,
cwd_source: PaneIdType,
