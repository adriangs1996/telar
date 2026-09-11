const Bookmarks = @This();
const source_namespace = @import("workspace_handoff_targeting.zig");
context: *anyopaque,
remembered_pane: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) ?source_namespace.schema.PaneId,
