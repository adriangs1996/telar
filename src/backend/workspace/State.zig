const state_support = @import("state_support.zig");
const WorkspaceType = @import("Workspace.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const State = @This();

items: [state_support.max_workspaces]?WorkspaceType = [_]?WorkspaceType{null} ** state_support.max_workspaces,
count: usize = 0,
git_probe: ?WorkspaceIdType = null,
next_workspace_id: u64 = 1,
next_tab_id: u64 = 1,
revision: u64 = 1,
