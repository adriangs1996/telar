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
/// The base the worker measured against when the row had none: the branch
/// its repository's main checkout stands on. Empty when the row had one.
found_base: [core.max_git_branch_bytes]u8 = undefined,
found_base_len: u8 = 0,
measured: bool = false,
stat: gitstatus.DiffStat = .{},
/// The limit Git ran past, for `finish` to report on the loop.
limit: ?core.LimitReach = null,

pub fn branchSlice(self: *const WorktreeProbeCompletion) []const u8 {
    return self.branch[0..self.branch_len];
}

pub fn foundBaseSlice(self: *const WorktreeProbeCompletion) []const u8 {
    return self.found_base[0..self.found_base_len];
}
