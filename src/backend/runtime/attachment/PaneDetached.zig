const core = @import("telar-core");
/// Committed removal of one pane from a client's disposable view state.
const PaneDetached = @This();

pane_id: core.PaneId,
workspace: core.WorkspaceLocation,
last_attachment: bool,
