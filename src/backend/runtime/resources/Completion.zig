const WorkspaceIdType = @import("telar-core").WorkspaceId;
const max_git_branch_bytes_module = @import("telar-core").max_git_branch_bytes;
const Completion = @This();

workspace: WorkspaceIdType,
present: bool = false,
branch: [max_git_branch_bytes_module]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,

pub fn branchSlice(completion: *const Completion) []const u8 {
    return completion.branch[0..completion.branch_len];
}
