const id = @import("../id.zig");
/// Reply to `register_worktree`: the tracked identity, and whether this
/// request created it or found it already tracked.
const WorktreeRegistered = @This();

request_id: id.RequestId,
worktree: id.WorktreeId,
created: bool,
