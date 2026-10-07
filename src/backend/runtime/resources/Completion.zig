const core = @import("telar-core");
const Completion = @This();

workspace: core.WorkspaceId,
present: bool = false,
// SAFETY: git_probe copies the observed branch before returning the completion; branchSlice reads only branch_len bytes.
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
/// Null when `git status` failed: unknown, not clean.
dirty: ?bool = null,
/// The limit Git ran past, for `finish` to report on the loop.
limit: ?core.LimitReach = null,

pub fn branchSlice(self: *const Completion) []const u8 {
    return self.branch[0..self.branch_len];
}
