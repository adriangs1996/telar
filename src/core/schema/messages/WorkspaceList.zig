const WorkspaceListEntry = @import("WorkspaceListEntry.zig");
const WorktreeListEntry = @import("WorktreeListEntry.zig");
const WorkspaceList = @This();

revision: u64,
entries: []const WorkspaceListEntry,
/// Tracked worktrees; a worktree's `workspace`, when set, is one of
/// `entries` that clients nest under `source` instead of listing it.
worktrees: []const WorktreeListEntry = &.{},
