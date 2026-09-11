const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneIdType = @import("telar-core").PaneId;
const TabCreationIntent = @This();

workspace: WorkspaceLocationType,
cwd_source: PaneIdType,
/// Borrowed only for the synchronous send callback.
label: []const u8,
arguments: []const []const u8 = &.{},
