const core = @import("telar-core");
/// One worktree's checkout and base, copied for a Git worker.
const WorktreeProbe = @This();

worktree: core.WorktreeId,
// SAFETY: worktree_git copies the checkout path before dispatching the probe; pathSlice reads only path_len bytes.
path: [core.max_cwd_bytes]u8 = undefined,
path_len: u16,
// SAFETY: worktree_git copies the base before dispatching the probe; baseSlice reads only base_len bytes.
base: [core.max_git_branch_bytes]u8 = undefined,
base_len: u8,

pub fn pathSlice(self: *const WorktreeProbe) []const u8 {
    return self.path[0..self.path_len];
}

pub fn baseSlice(self: *const WorktreeProbe) []const u8 {
    return self.base[0..self.base_len];
}
