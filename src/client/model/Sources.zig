const SnapshotType = @import("../agents/AgentSnapshot.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const TabsModel = @import("../workspace/TabsModel.zig");
const Sources = @This();

agents: *const SnapshotType,
workspaces: *const WorkspaceListSnapshot,
tabs: ?*const TabsModel,
