const TabCreationIntent = @This();
const source_namespace = @import("create_tab.zig");
workspace: source_namespace.schema.WorkspaceLocation,
cwd_source: source_namespace.schema.PaneId,
/// Borrowed only for the synchronous send callback.
label: []const u8,
arguments: []const []const u8 = &.{},
