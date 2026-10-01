const core = @import("telar-core");
const MachineWorktree = @This();

slot: u8,
machine_generation: u64,
worktree: core.WorktreeId,
workspace: core.WorkspaceId,
