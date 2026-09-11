/// Committed removal of one pane from a client's disposable view state.
const PaneDetached = @This();
const source_namespace = @import("root.zig");
pane_id: source_namespace.schema.PaneId,
workspace: source_namespace.schema.WorkspaceLocation,
last_attachment: bool,
