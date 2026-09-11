const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceTabInput = @import("WorkspaceTabInput.zig");
const WorkspaceSnapshotInput = @This();

workspace: WorkspaceLocationType,
name: []const u8,
/// Borrowed only for synchronous reconciliation. Slice order is the
/// canonical runtime tab order.
tabs: []const WorkspaceTabInput,
