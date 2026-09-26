const core = @import("telar-core");
const std = @import("std");
const Entry = @import("Entry.zig");
const workspace_list = @import("workspace_list.zig");
const SnapshotInput = @import("WorkspaceListInput.zig");
const WorktreeRow = @import("WorktreeRow.zig");
const EntryInput = @import("EntryInput.zig");
const Snapshot = @This();

revision: u64 = 0,
count: usize = 0,
/// Entries before this index are projects; the rest hold worktree tabs and
/// hang from their source in every view.
project_count: usize = 0,
entries: [core.max_workspace_list_entries]Entry = undefined,
worktrees: [core.max_worktree_entries]WorktreeRow = undefined,
worktree_count: usize = 0,
path_pool: [workspace_list.path_pool_size]u8 = undefined,
pool_len: usize = 0,

/// Atomically stores one newer runtime snapshot in fixed memory.
///
/// ```zig
/// _ = try snapshot.replace(.{ .revision = 1, .entries = entries });
/// ```
pub fn replace(self: *Snapshot, input: SnapshotInput) !bool {
    if (input.revision <= self.revision) {
        return false;
    }
    if (input.entries.len > core.max_workspace_list_entries) {
        return error.TooManyWorkspaces;
    }

    if (input.worktrees.len > core.max_worktree_entries) {
        return error.TooManyWorktrees;
    }

    var replacement: Snapshot = .{
        .revision = input.revision,
        .count = input.entries.len,
    };

    for (input.worktrees, 0..) |worktree_input, index| {
        replacement.worktrees[index] = .init(worktree_input);
    }

    replacement.worktree_count = input.worktrees.len;
    var ordered: [core.max_workspace_list_entries]EntryInput = undefined;
    var ordered_len: usize = 0;
    for (input.entries) |entry| {
        if (!holdsWorktree(input, entry.workspace)) {
            ordered[ordered_len] = entry;
            ordered_len += 1;
        }
    }

    replacement.project_count = ordered_len;
    for (input.entries) |entry| {
        if (holdsWorktree(input, entry.workspace)) {
            ordered[ordered_len] = entry;
            ordered_len += 1;
        }
    }

    for (ordered[0..ordered_len], 0..) |entry, index| {
        if (entry.path.len > core.max_cwd_bytes) {
            return error.WorkspacePathTooLong;
        }
        if (replacement.pool_len + entry.path.len > workspace_list.path_pool_size) {
            return error.WorkspaceListTooLarge;
        }

        for (ordered[0..index]) |previous| {
            if (previous.workspace == entry.workspace) {
                return error.DuplicateWorkspace;
            }
        }

        const name = workspace_list.truncateName(entry.name);
        var stored: Entry = .{
            .workspace = entry.workspace,
            .name = undefined,
            .name_len = @intCast(name.len),
            .path_offset = @intCast(replacement.pool_len),
            .path_len = @intCast(entry.path.len),
            .tab_count = entry.tab_count,
        };
        const branch = entry.branch[0..@min(entry.branch.len, stored.branch.len)];
        @memcpy(stored.branch[0..branch.len], branch);
        stored.branch_len = @intCast(branch.len);
        stored.dirty = entry.dirty;
        @memcpy(stored.name[0..name.len], name);
        @memcpy(replacement.path_pool[replacement.pool_len..][0..entry.path.len], entry.path);
        replacement.pool_len += entry.path.len;
        replacement.entries[index] = stored;
    }

    self.* = replacement;
    return true;
}

/// Returns one git branch borrowed from the snapshot, empty when unknown.
///
/// ```zig
/// const branch = snapshot.branchAt(0);
/// ```
pub fn branchAt(self: *const Snapshot, index: usize) []const u8 {
    const entry = &self.entries[index];
    return entry.branch[0..entry.branch_len];
}

/// Returns one display name borrowed from the snapshot.
///
/// ```zig
/// const name = snapshot.nameAt(0);
/// ```
pub fn nameAt(self: *const Snapshot, index: usize) []const u8 {
    const entry = &self.entries[index];
    return entry.name[0..entry.name_len];
}

/// Returns one complete workspace path borrowed from the snapshot.
///
/// ```zig
/// const path = snapshot.pathAt(0);
/// ```
pub fn pathAt(self: *const Snapshot, index: usize) []const u8 {
    const entry = &self.entries[index];
    return self.path_pool[entry.path_offset..][0..entry.path_len];
}

/// Returns the workspace identity at a known valid index.
///
/// ```zig
/// const workspace = snapshot.workspaceAt(0);
/// ```
pub fn workspaceAt(self: *const Snapshot, index: usize) core.WorkspaceId {
    return self.entries[index].workspace;
}

/// Resolves a bounded zero-based navigation position among projects.
///
/// ```zig
/// const workspace = snapshot.workspaceAtPosition(0) orelse return;
/// ```
pub fn workspaceAtPosition(self: *const Snapshot, position: usize) ?core.WorkspaceId {
    if (position >= self.project_count) {
        return null;
    }

    return self.workspaceAt(position);
}

/// The worktree whose tabs live in `workspace`.
///
/// ```zig
/// const row = snapshot.worktreeOfWorkspace(workspace) orelse return;
/// ```
pub fn worktreeOfWorkspace(self: *const Snapshot, workspace: core.WorkspaceId) ?*const WorktreeRow {
    for (self.worktrees[0..self.worktree_count]) |*row| {
        if (row.workspace == workspace) {
            return row;
        }
    }

    return null;
}

/// The tracked worktree with `id`.
/// Example: `const row = snapshot.worktree(agent.work_tree) orelse return;`.
pub fn worktree(self: *const Snapshot, id: core.WorktreeId) ?*const WorktreeRow {
    if (id == .invalid) {
        return null;
    }

    for (self.worktrees[0..self.worktree_count]) |*row| {
        if (row.worktree == id) {
            return row;
        }
    }

    return null;
}

/// The project a workspace belongs to: the source of the worktree it holds,
/// else itself.
///
/// ```zig
/// const project = snapshot.projectOf(workspace);
/// ```
pub fn projectOf(self: *const Snapshot, workspace: core.WorkspaceId) core.WorkspaceId {
    const row = self.worktreeOfWorkspace(workspace) orelse return workspace;
    return if (self.indexOf(row.source)) |_| row.source else workspace;
}

/// Whether the pane `pane_id` delegated any tracked worktree: the
/// coordinator of those tasks.
/// Example: `if (snapshot.delegates(agent.key.pane_id)) drawCoordinatorMark();`.
pub fn delegates(self: *const Snapshot, pane_id: core.PaneId) bool {
    for (self.worktrees[0..self.worktree_count]) |*row| {
        if (row.created_by == pane_id) {
            return true;
        }
    }

    return false;
}

/// How many tracked worktrees hang from project `workspace`.
/// Example: `const count = snapshot.worktreeCount(workspace);`.
pub fn worktreeCount(self: *const Snapshot, workspace: core.WorkspaceId) usize {
    var count: usize = 0;
    for (self.worktrees[0..self.worktree_count]) |*row| {
        count += @intFromBool(row.source == workspace);
    }

    return count;
}

/// Finds a runtime workspace identity without exposing entry storage.
///
/// ```zig
/// const index = snapshot.indexOf(workspace) orelse return;
/// ```
pub fn indexOf(self: *const Snapshot, workspace: core.WorkspaceId) ?usize {
    for (self.entries[0..self.count], 0..) |entry, index| {
        if (entry.workspace == workspace) {
            return index;
        }
    }

    return null;
}

fn holdsWorktree(input: SnapshotInput, workspace: core.WorkspaceId) bool {
    for (input.worktrees) |worktree_input| {
        if (worktree_input.workspace == workspace) {
            return true;
        }
    }

    return false;
}

test "worktree workspaces follow the projects and resolve to their source" {
    var snapshot: Snapshot = .{};
    _ = try snapshot.replace(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(5), .name = "fix", .path = "/w/fix", .tab_count = 1 },
            .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 2 },
        },
        .worktrees = &.{
            .{ .worktree = @enumFromInt(9), .source = @enumFromInt(1), .workspace = @enumFromInt(5), .branch = "fix", .title = "Fix tabs" },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), snapshot.project_count);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), snapshot.workspaceAtPosition(0).?);
    try std.testing.expect(snapshot.workspaceAtPosition(1) == null);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), snapshot.projectOf(@enumFromInt(5)));
    try std.testing.expectEqualStrings("Fix tabs", snapshot.worktreeOfWorkspace(@enumFromInt(5)).?.displayName());
    try std.testing.expectEqual(@as(usize, 1), snapshot.worktreeCount(@enumFromInt(1)));
}
