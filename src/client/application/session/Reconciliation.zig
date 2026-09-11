const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Reconciliation = @This();

required_workspace: WorkspaceLocationType,
projected_workspace: ?WorkspaceLocationType,
snapshot_pending: bool,
