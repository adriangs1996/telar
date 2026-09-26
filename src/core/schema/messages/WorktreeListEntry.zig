const id = @import("../id.zig");
const types = @import("../types.zig");
/// One tracked worktree in the workspace list.
const WorktreeListEntry = @This();

worktree: id.WorktreeId,
source: id.WorkspaceId,
/// The workspace holding the worktree's tabs, once something was launched.
workspace: ?id.WorkspaceId = null,
created_by: ?id.PaneId = null,
origin: types.WorktreeOrigin = .telar,
state: types.WorktreeState = .active,
path: []const u8,
branch: []const u8,
base: []const u8 = "",
title: []const u8 = "",
brief: []const u8 = "",
diff_added: u32 = 0,
diff_removed: u32 = 0,
diff_files: u32 = 0,
commits_ahead: u32 = 0,
command_label: []const u8 = "",
command_state: types.CommandState = .none,
command_exit: i32 = 0,
