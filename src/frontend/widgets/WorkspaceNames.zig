const WorkspaceNames = @This();
const workspace_list = @import("telar-client").workspace.workspace_list;
snapshot: *const workspace_list.Snapshot,
active_index: ?usize,
active_name: []const u8,
