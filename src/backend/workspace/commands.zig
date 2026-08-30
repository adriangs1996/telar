//! Domain command handlers for workspace aggregates stored by a repository.

const std = @import("std");
const core = @import("telar-core");
const repository_mod = @import("repository.zig");
const state_mod = @import("state.zig");

const schema = core.schema;
const Repository = repository_mod.Repository;

pub const TabCreated = struct {
    location: schema.TabLocation,
    position: u16,
};

pub const TabRemoval = struct {
    workspace_closed: bool,
    previous_workspace: ?schema.WorkspaceId = null,
};

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

/// Creates a tab with a globally stable identity. Identity and list revision
/// are committed only after the aggregate accepts the requested label.
///
/// ```zig
/// const created = try createTab(&repository, workspace, "logs");
/// ```
pub fn createTab(repository: *Repository, location: schema.WorkspaceLocation, label: []const u8) !TabCreated {
    const workspace = repository.find(location) orelse return error.WorkspaceNotFound;
    const tab_id = try repository.nextTabId();
    const created = try workspace.createTab(tab_id, label);
    repository.recordTabCreated(tab_id);

    return .{
        .location = .{ .workspace = location, .tab_id = created.id },
        .position = created.position,
    };
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

/// Removes a tab and removes its workspace aggregate when no tabs remain.
/// The result carries the stable predecessor clients should focus next.
///
/// ```zig
/// const removal = removeTab(&repository, location) orelse return;
/// ```
pub fn removeTab(repository: *Repository, location: schema.TabLocation) ?TabRemoval {
    const workspace = repository.find(location.workspace) orelse return null;

    if (!workspace.removeTab(location.tab_id)) {
        return null;
    }

    repository.recordListChange();
    const workspace_closed = workspace.tabCount() == 0;
    var previous_workspace: ?schema.WorkspaceId = null;

    if (workspace_closed) {
        const workspace_id = switch (location.workspace) {
            .workspace => |id| id,
            .worktree => unreachable,
        };
        previous_workspace = repository.reader().previousWorkspace(workspace_id);
        const removed = repository.remove(workspace_id);
        std.debug.assert(removed);
    }

    return .{
        .workspace_closed = workspace_closed,
        .previous_workspace = previous_workspace,
    };
}

fn insertWorkspace(repository: *Repository, path: []const u8) !schema.TabLocation {
    return repository.insert(.{ .path = path });
}

test "failed tab creation does not consume its candidate identity" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial = try insertWorkspace(&repository, "/work/project");
    const initial_revision = repository.reader().revision();
    const oversized_label: [schema.max_tab_label_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(
        error.InvalidTabLabel,
        createTab(&repository, initial.workspace, &oversized_label),
    );
    try std.testing.expectEqual(initial_revision, repository.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), repository.reader().totalTabs());

    const created = try createTab(&repository, initial.workspace, "logs");
    try std.testing.expectEqual(@as(u64, 2), schema.id.raw(created.location.tab_id));
}

test "workspace commands create move and remove tabs with list revisions" {
    var state: state_mod.State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial = try insertWorkspace(&repository, "/work/project");
    const before_create = repository.reader().revision();

    const logs = try createTab(&repository, initial.workspace, "logs");
    try std.testing.expect(repository.reader().revision() != before_create);
    try std.testing.expectEqualStrings("logs", repository.reader().tabLabel(logs.location).?);

    try std.testing.expectEqual(@as(u16, 0), try moveTab(&repository, logs.location, .previous));
    try std.testing.expectEqual(logs.location.tab_id, repository.reader().defaultTab(initial.workspace).?);

    const first_removal = removeTab(&repository, initial).?;
    try std.testing.expect(!first_removal.workspace_closed);
    const final_removal = removeTab(&repository, logs.location).?;
    try std.testing.expect(final_removal.workspace_closed);
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
    try std.testing.expect(middle.workspace_closed);
    try std.testing.expectEqual(first_id, middle.previous_workspace.?);

    const wrapped = removeTab(&repository, first).?;
    try std.testing.expect(wrapped.workspace_closed);
    try std.testing.expectEqual(third_id, wrapped.previous_workspace.?);

    const last = removeTab(&repository, third).?;
    try std.testing.expect(last.workspace_closed);
    try std.testing.expect(last.previous_workspace == null);
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
