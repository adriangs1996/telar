const core = @import("telar-core");
/// One worktree's checkout and base, copied for a Git worker.
const WorktreeProbe = @This();

worktree: core.WorktreeId,
path: [core.max_cwd_bytes]u8 = undefined,
path_len: u16,
base: [core.max_git_branch_bytes]u8 = undefined,
base_len: u8,

pub fn pathSlice(self: *const WorktreeProbe) []const u8 {
    return self.path[0..self.path_len];
}

pub fn baseSlice(self: *const WorktreeProbe) []const u8 {
    return self.base[0..self.base_len];
}
