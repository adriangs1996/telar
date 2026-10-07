const core = @import("telar-core");
const workspace_list = @import("workspace_list.zig");

workspace: core.WorkspaceId,
name: [workspace_list.max_name_bytes]u8,
name_len: u16,
path_offset: u32,
path_len: u32,
tab_count: u16,
// SAFETY: WorkspaceListSnapshot.replace copies the branch before publishing the entry; branchAt reads only branch_len bytes.
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,
