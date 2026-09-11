const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
/// Committed removal of one pane from a client's disposable view state.
const PaneDetached = @This();

pane_id: PaneIdType,
workspace: WorkspaceLocationType,
last_attachment: bool,
