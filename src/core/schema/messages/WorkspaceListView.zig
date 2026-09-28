const WorkspaceListIterator = @import("WorkspaceListIterator.zig");
const WorktreeListIterator = @import("WorktreeListIterator.zig");
const WorkspaceListView = @This();

revision: u64,
entry_count: u16,
encoded_entries: []const u8,
worktree_count: u16 = 0,
encoded_worktrees: []const u8 = &.{},

pub fn entries(self: WorkspaceListView) WorkspaceListIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}

/// Iterates the tracked worktrees. Example: `var worktrees = view.worktrees();`
pub fn worktrees(self: WorkspaceListView) WorktreeListIterator {
    return .{
        .decoder = .init(self.encoded_worktrees),
        .remaining = self.worktree_count,
    };
}
