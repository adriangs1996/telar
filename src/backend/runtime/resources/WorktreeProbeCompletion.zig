const core = @import("telar-core");
const gitstatus = @import("gitstatus");
/// What a worktree Git worker found: whether the checkout still exists, its
/// branch and local changes, and its distance from its base when Git could
/// measure it in time.
const WorktreeProbeCompletion = @This();

worktree: core.WorktreeId,
present: bool = false,
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,
measured: bool = false,
stat: gitstatus.DiffStat = .{},

pub fn branchSlice(self: *const WorktreeProbeCompletion) []const u8 {
    return self.branch[0..self.branch_len];
}
