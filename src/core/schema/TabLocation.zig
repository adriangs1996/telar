/// Persistent identity of a tab and therefore of the pane layout it owns.
const TabLocation = @This();
const source_namespace = @import("types.zig");
const id = @import("id.zig");
workspace: source_namespace.WorkspaceLocation,
tab_id: id.TabId,
