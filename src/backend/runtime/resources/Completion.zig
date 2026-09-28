const core = @import("telar-core");
const Completion = @This();

workspace: core.WorkspaceId,
present: bool = false,
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
/// Null when `git status` failed: unknown, not clean.
dirty: ?bool = null,

pub fn branchSlice(self: *const Completion) []const u8 {
    return self.branch[0..self.branch_len];
}
