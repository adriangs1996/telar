const core = @import("telar-core");
const Completion = @This();

workspace: core.WorkspaceId,
present: bool = false,
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,

pub fn branchSlice(completion: *const Completion) []const u8 {
    return completion.branch[0..completion.branch_len];
}
