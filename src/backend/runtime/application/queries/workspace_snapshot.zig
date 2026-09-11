//! Application query for a workspace snapshot reference.

const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const WorkspaceSnapshotHandler = @import("WorkspaceSnapshotHandler.zig");
const workspace_module = @import("telar-core").workspace;
const worktree_module = @import("telar-core").worktree;

test "Handler returns an existing workspace snapshot reference" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    var handler: WorkspaceSnapshotHandler = .{ .workspaces = workspaces.reader() };

    const result = try handler.executor().execute(.{ .location = location });

    try std.testing.expectEqualDeep(location, result.location);
}

test "Handler rejects missing workspace identities" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var handler: WorkspaceSnapshotHandler = .{ .workspaces = workspaces.reader() };

    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .workspace = try workspace_module(999) },
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .worktree = try worktree_module(999) },
    }));
}
