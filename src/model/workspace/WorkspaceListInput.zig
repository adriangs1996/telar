const EntryInput = @import("EntryInput.zig");
const WorktreeInput = @import("WorktreeInput.zig");
const WorkspaceListInput = @This();

revision: u64,
entries: []const EntryInput,
worktrees: []const WorktreeInput = &.{},
