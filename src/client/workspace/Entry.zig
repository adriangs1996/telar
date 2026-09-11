const Entry = @This();
const source_namespace = @import("workspace_list.zig");
workspace: source_namespace.schema.WorkspaceId,
name: [source_namespace.max_name_bytes]u8,
name_len: u8,
path_offset: u32,
path_len: u32,
tab_count: u16,
branch: [source_namespace.schema.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,
