const SnapshotType = @import("../agents/AgentSnapshot.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const Model = @import("Model.zig");
const Sources = @This();

agents: *const SnapshotType,
workspaces: *const WorkspaceListSnapshot,
/// The client model whose active workspace tabs the picker lists.
model: ?*const Model,
