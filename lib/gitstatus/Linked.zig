/// A Git linked worktree: its checkout root and the branch its HEAD names.
/// Both borrow the caller's buffers.
root: []const u8,
branch: []const u8,
