//! A working tree's branch and whether it has uncommitted changes.
const Status = @This();

/// The ref's last component, or a short hash for a detached HEAD.
branch: []const u8,
/// Null when `git status` failed or timed out: unknown, never clean.
dirty: ?bool,
/// Whether `git status` ran past its timeout, `probe.status_timeout_ms`.
timed_out: bool = false,
