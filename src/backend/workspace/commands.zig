//! Domain command handlers for workspace aggregates stored by a repository.

const std = @import("std");
const core = @import("telar-core");
const events = @import("events.zig");
const repository_mod = @import("repository.zig");
const state_mod = @import("state.zig");

const schema = core.schema;
const Repository = repository_mod.Repository;

/// Renames an existing aggregate and advances the workspace-list projection.
///
/// ```zig
/// try renameWorkspace(&repository, location, "backend");
/// ```
pub fn renameWorkspace(repository: *Repository, location: schema.WorkspaceLocation, name: []const u8) !void {
    const workspace = repository.find(location) orelse return error.WorkspaceNotFound;
    try workspace.rename(name);
    repository.recordListChange();
}

/// Reorders one tab inside its aggregate without changing list revision.
///
/// ```zig
/// const position = try moveTab(&repository, location, .previous);
/// ```
pub fn moveTab(repository: *Repository, location: schema.TabLocation, direction: schema.TabMoveDirection) !u16 {
    const workspace = repository.find(location.workspace) orelse return error.WorkspaceNotFound;
    return workspace.moveTab(location.tab_id, direction) orelse error.TabNotFound;
}

/// Removes a tab and its now-empty workspace as one domain operation. The
/// returned event contains the stable predecessor of a removed workspace.
///
/// ```zig
/// const removed = removeTab(&repository, location) orelse return;
/// ```
pub fn removeTab(repository: *Repository, location: schema.TabLocation) ?events.TabRemoved {
    const workspace = repository.find(location.workspace) orelse return null;

    if (!workspace.removeTab(location.tab_id)) {
        return null;
    }

    repository.recordListChange();
    const workspace_removed = workspace.tabCount() == 0;
    var previous_workspace: ?schema.WorkspaceId = null;

    if (workspace_removed) {
        const workspace_id = switch (location.workspace) {
            .workspace => |id| id,
            .worktree => unreachable,
        };
        previous_workspace = repository.reader().previousWorkspace(workspace_id);
        const removed = repository.remove(workspace_id);
        std.debug.assert(removed);
    }

    return events.TabRemoved.init(location, workspace_removed, previous_workspace) catch unreachable;
}

fn insertWorkspace(repository: *Repository, path: []const u8) !schema.TabLocation {
    return repository.insert(.{ .path = path });
}

fn insertTestingTab(repository: *Repository, location: schema.WorkspaceLocation, label: []const u8) !schema.TabLocation {
    const workspace = repository.find(location) orelse return error.WorkspaceNotFound;
    const tab_id = try repository.nextTabId();
    const created = try workspace.createTab(tab_id, label);
    repository.recordTabCreated(tab_id);
    return created.location;
}

test "workspace commands move and remove tabs around repository state" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial = try insertWorkspace(&repository, "/work/project");
    const logs = try insertTestingTab(&repository, initial.workspace, "logs");
    try std.testing.expectEqualStrings("logs", repository.reader().tabLabel(logs).?);

    const before_move = repository.reader().revision();
    try std.testing.expectEqual(@as(u16, 0), try moveTab(&repository, logs, .previous));
    try std.testing.expectEqual(logs.tab_id, repository.reader().defaultTab(initial.workspace).?);
    try std.testing.expectEqual(before_move, repository.reader().revision());

    const before_remove = repository.reader().revision();
    const first_removal = removeTab(&repository, initial).?;
    try std.testing.expect(!first_removal.workspace_removed);
    try std.testing.expectEqualDeep(initial, first_removal.location);
    try std.testing.expectEqual(before_remove + 1, repository.reader().revision());
    const before_final_remove = repository.reader().revision();
    const final_removal = removeTab(&repository, logs).?;
    try std.testing.expect(final_removal.workspace_removed);
    try std.testing.expectEqualDeep(logs, final_removal.location);
    try std.testing.expect(repository.reader().revision() != before_final_remove);
    try std.testing.expectEqual(@as(usize, 0), repository.reader().count());
}

test "closing workspaces returns the predecessor from repository order" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const first = try insertWorkspace(&repository, "/work/first");
    const second = try insertWorkspace(&repository, "/work/second");
    const third = try insertWorkspace(&repository, "/work/third");
    const first_id = switch (first.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    const third_id = switch (third.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };

    const middle = removeTab(&repository, second).?;
    try std.testing.expect(middle.workspace_removed);
    try std.testing.expectEqual(first_id, middle.previous_workspace.?);

    const wrapped = removeTab(&repository, first).?;
    try std.testing.expect(wrapped.workspace_removed);
    try std.testing.expectEqual(third_id, wrapped.previous_workspace.?);

    const last = removeTab(&repository, third).?;
    try std.testing.expect(last.workspace_removed);
    try std.testing.expect(last.previous_workspace == null);
}

test "removing a missing tab leaves repository state unchanged" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const existing = try insertWorkspace(&repository, "/work/project");
    const revision = repository.reader().revision();
    const missing: schema.TabLocation = .{
        .workspace = existing.workspace,
        .tab_id = try schema.id.tab(999),
    };

    try std.testing.expect(removeTab(&repository, missing) == null);
    try std.testing.expect(repository.reader().contains(existing));
    try std.testing.expectEqual(revision, repository.reader().revision());
}

test "workspace rename is aggregate behavior recorded by the repository" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const location = try insertWorkspace(&repository, "/work/project");
    const before = repository.reader().revision();

    try renameWorkspace(&repository, location.workspace, "agents");

    try std.testing.expectEqualStrings("agents", repository.reader().workspaceName(location.workspace).?);
    try std.testing.expect(repository.reader().revision() != before);
}
