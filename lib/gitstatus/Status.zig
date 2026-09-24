//! A working tree's branch and whether it has uncommitted changes.
const Status = @This();

/// The ref's last component, or a short hash for a detached HEAD.
branch: []const u8,
dirty: bool,
