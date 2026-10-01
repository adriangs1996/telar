const core = @import("telar-core");
/// One tracked worktree as the runtime's workspace list carries it; slices
/// borrow the decoded message.
const WorktreeInput = @This();

worktree: core.WorktreeId,
source: core.WorkspaceId,
workspace: ?core.WorkspaceId = null,
created_by: ?core.PaneId = null,
coordinator: ?core.CoordinatorReference = null,
state: core.WorktreeState = .active,
path: []const u8 = "",
branch: []const u8,
base: []const u8 = "",
title: []const u8 = "",
diff_added: u32 = 0,
diff_removed: u32 = 0,
diff_files: u32 = 0,
commits_ahead: u32 = 0,
command_label: []const u8 = "",
command_state: core.CommandState = .none,
command_exit: i32 = 0,
