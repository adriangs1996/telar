const types = @import("types.zig");
const id = @import("id.zig");
/// Persistent identity of a tab and therefore of the pane layout it owns.
const TabLocation = @This();

workspace: types.WorkspaceLocation,
tab_id: id.TabId,
