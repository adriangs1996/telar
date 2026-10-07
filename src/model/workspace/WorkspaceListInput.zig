const EntryInput = @import("EntryInput.zig");
const WorktreeInput = @import("WorktreeInput.zig");

revision: u64,
entries: []const EntryInput,
worktrees: []const WorktreeInput = &.{},
