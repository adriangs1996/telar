const id = @import("../id.zig");
/// Stops tracking a worktree and closes every tab of its workspace. The
/// checkout itself is removed by the CLI, never by the runtime.
const ForgetWorktree = @This();

request_id: id.RequestId,
worktree: id.WorktreeId,
