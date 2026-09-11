const Reconciliation = @This();
const source_namespace = @import("resync_required.zig");
required_workspace: source_namespace.schema.WorkspaceLocation,
projected_workspace: ?source_namespace.schema.WorkspaceLocation,
snapshot_pending: bool,
