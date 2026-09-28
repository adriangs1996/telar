/// Which changes `diff` shows.
pub const DiffScope = enum {
    /// Everything since the worktree left its base: commits and local edits.
    branch,
    /// Only what is not committed yet.
    uncommitted,
};
