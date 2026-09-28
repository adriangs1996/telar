const core = @import("telar-core");
const PaneKey = @import("../../pane/PaneKey.zig");
/// What the worker found above a pane's directory: the checkout root of the
/// linked worktree it lies in, as a prefix of that directory, and the branch
/// its HEAD names. A zero `root_len` means none, or one the runtime cannot
/// track whole.
const WorktreeDetectionCompletion = @This();

pane: PaneKey,
cwd_revision: u64,
root_len: u16 = 0,
branch: [core.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,

pub fn branchSlice(self: *const WorktreeDetectionCompletion) []const u8 {
    return self.branch[0..self.branch_len];
}
