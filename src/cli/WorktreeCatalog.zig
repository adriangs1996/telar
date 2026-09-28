const std = @import("std");
const core = @import("telar-core");
const CatalogWorkspace = @import("CatalogWorkspace.zig");
const CatalogWorktree = @import("CatalogWorktree.zig");
/// The runtime's workspaces and tracked worktrees as the CLI copies them from
/// one workspace list, so commands can resolve branches, titles and paths
/// after the receive buffer is reused. Strings live in the catalog's arena.
const WorktreeCatalog = @This();

arena: std.heap.ArenaAllocator,
workspaces: std.ArrayList(CatalogWorkspace) = .empty,
worktrees: std.ArrayList(CatalogWorktree) = .empty,

pub fn init(gpa: std.mem.Allocator) WorktreeCatalog {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(self: *WorktreeCatalog) void {
    self.arena.deinit();
}

/// Copies one workspace list into the catalog, replacing what it held.
///
/// ```zig
/// try catalog.copy(response.workspace_list);
/// ```
pub fn copy(self: *WorktreeCatalog, list: core.WorkspaceListView) !void {
    _ = self.arena.reset(.retain_capacity);
    self.workspaces = .empty;
    self.worktrees = .empty;
    const arena = self.arena.allocator();

    var entries = list.entries();
    while (try entries.next()) |entry| {
        try self.workspaces.append(arena, .{
            .id = core.raw(entry.workspace),
            .name = try arena.dupe(u8, entry.name),
            .path = try arena.dupe(u8, entry.path),
            .branch = try arena.dupe(u8, entry.branch),
            .dirty = entry.dirty,
        });
    }

    var worktrees = list.worktrees();
    while (try worktrees.next()) |entry| {
        try self.worktrees.append(arena, .{
            .id = entry.worktree,
            .source = core.raw(entry.source),
            .workspace = if (entry.workspace) |id| core.raw(id) else null,
            .created_by = if (entry.created_by) |id| core.raw(id) else null,
            .origin = entry.origin,
            .state = entry.state,
            .path = try arena.dupe(u8, entry.path),
            .branch = try arena.dupe(u8, entry.branch),
            .base = try arena.dupe(u8, entry.base),
            .title = try arena.dupe(u8, entry.title),
            .brief = try arena.dupe(u8, entry.brief),
            .dispatched_from = try arena.dupe(u8, entry.dispatched_from),
            .diff_added = entry.diff_added,
            .diff_removed = entry.diff_removed,
            .diff_files = entry.diff_files,
            .commits_ahead = entry.commits_ahead,
            .command_label = try arena.dupe(u8, entry.command_label),
            .command_state = entry.command_state,
            .command_exit = entry.command_exit,
        });
    }
}

/// The worktree a CLI reference names: its exact branch, else a unique
/// case-insensitive title. Two projects may share a branch name; then the
/// branch names neither and the title has to.
///
/// ```zig
/// const worktree = try catalog.find("fix-tabs") orelse return error.WorktreeNotFound;
/// ```
pub fn find(self: *const WorktreeCatalog, reference: []const u8) !?*const CatalogWorktree {
    var by_branch: ?*const CatalogWorktree = null;
    for (self.worktrees.items) |*worktree| {
        if (!std.mem.eql(u8, worktree.branch, reference)) {
            continue;
        }

        if (by_branch != null) {
            return error.AmbiguousWorktree;
        }

        by_branch = worktree;
    }

    if (by_branch) |worktree| {
        return worktree;
    }

    var found: ?*const CatalogWorktree = null;
    for (self.worktrees.items) |*worktree| {
        if (!std.ascii.eqlIgnoreCase(worktree.title, reference)) {
            continue;
        }

        if (found != null) {
            return error.AmbiguousWorktree;
        }

        found = worktree;
    }

    return found;
}

pub fn findId(self: *const WorktreeCatalog, id: core.WorktreeId) ?*const CatalogWorktree {
    for (self.worktrees.items) |*worktree| {
        if (worktree.id == id) {
            return worktree;
        }
    }

    return null;
}

pub fn findWorkspace(self: *const WorktreeCatalog, id: u64) ?*const CatalogWorkspace {
    for (self.workspaces.items) |*workspace| {
        if (workspace.id == id) {
            return workspace;
        }
    }

    return null;
}

/// The first workspace whose path is exactly `path`, skipping the ones that
/// hold a worktree's tabs.
///
/// ```zig
/// const source = catalog.workspaceAt("/src/telar") orelse return error.WorkspaceNotFound;
/// ```
pub fn workspaceAt(self: *const WorktreeCatalog, path: []const u8) ?*const CatalogWorkspace {
    for (self.workspaces.items) |*workspace| {
        if (std.mem.eql(u8, workspace.path, path) and !self.holdsWorktree(workspace.id)) {
            return workspace;
        }
    }

    return null;
}

/// Whether workspace `id` holds the tabs of a tracked worktree.
pub fn holdsWorktree(self: *const WorktreeCatalog, id: u64) bool {
    for (self.worktrees.items) |*worktree| {
        if (worktree.workspace == id) {
            return true;
        }
    }

    return false;
}

test "references resolve by branch first and by unique title" {
    var catalog: WorktreeCatalog = .init(std.testing.allocator);
    defer catalog.deinit();
    const arena = catalog.arena.allocator();
    try catalog.worktrees.append(arena, sample(1, "fix", "Fix tabs"));
    try catalog.worktrees.append(arena, sample(2, "links", "Path links"));

    try std.testing.expectEqual(@as(core.WorktreeId, @enumFromInt(1)), (try catalog.find("fix")).?.id);
    try std.testing.expectEqual(@as(core.WorktreeId, @enumFromInt(2)), (try catalog.find("path LINKS")).?.id);
    try std.testing.expect((try catalog.find("missing")) == null);

    try catalog.worktrees.append(arena, sample(3, "other", "Path links"));
    try std.testing.expectError(error.AmbiguousWorktree, catalog.find("path links"));
}

test "a branch two projects share names neither of their worktrees" {
    var catalog: WorktreeCatalog = .init(std.testing.allocator);
    defer catalog.deinit();
    const arena = catalog.arena.allocator();
    try catalog.worktrees.append(arena, sample(1, "fix", "Fix tabs"));
    try catalog.worktrees.append(arena, sample(2, "fix", "Fix links"));

    try std.testing.expectError(error.AmbiguousWorktree, catalog.find("fix"));
    try std.testing.expectEqual(@as(core.WorktreeId, @enumFromInt(2)), (try catalog.find("Fix links")).?.id);
}

fn sample(id: u64, branch: []const u8, title: []const u8) CatalogWorktree {
    return .{
        .id = @enumFromInt(id),
        .source = 1,
        .workspace = null,
        .created_by = null,
        .origin = .telar,
        .state = .active,
        .path = "/w",
        .branch = branch,
        .base = "main",
        .title = title,
        .brief = "",
        .diff_added = 0,
        .diff_removed = 0,
        .diff_files = 0,
        .commits_ahead = 0,
        .command_label = "",
        .command_state = .none,
        .command_exit = 0,
    };
}
