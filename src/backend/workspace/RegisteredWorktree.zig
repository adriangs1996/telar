const core = @import("telar-core");
/// The row a registration resolved to.
const RegisteredWorktree = @This();

id: core.WorktreeId,
slot: usize,
created: bool,
