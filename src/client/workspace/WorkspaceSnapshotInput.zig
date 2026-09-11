const WorkspaceSnapshotInput = @This();
const source_namespace = @import("tabs.zig");
const WorkspaceTabInput = @import("WorkspaceTabInput.zig");
workspace: source_namespace.schema.WorkspaceLocation,
name: []const u8,
/// Borrowed only for synchronous reconciliation. Slice order is the
/// canonical runtime tab order.
tabs: []const WorkspaceTabInput,
