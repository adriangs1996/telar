const WorkspaceIdType = @import("telar-core").WorkspaceId;
const workspace_list = @import("workspace_list.zig");
const max_git_branch_bytes_module = @import("telar-core").max_git_branch_bytes;
const Entry = @This();

workspace: WorkspaceIdType,
name: [workspace_list.max_name_bytes]u8,
name_len: u8,
path_offset: u32,
path_len: u32,
tab_count: u16,
branch: [max_git_branch_bytes_module]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,
