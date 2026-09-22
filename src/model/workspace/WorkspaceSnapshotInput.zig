const core = @import("telar-core");
const data = @import("../model.zig");
const WorkspaceSnapshotInput = @This();

workspace: core.WorkspaceLocation,
name: []const u8,
/// Borrowed only for synchronous reconciliation. Slice order is the
/// canonical runtime tab order.
tabs: []const data.WorkspaceTabInput,
