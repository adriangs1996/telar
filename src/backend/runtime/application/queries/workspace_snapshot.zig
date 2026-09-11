//! Application query for a workspace snapshot reference.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;

pub const Request = @import("WorkspaceSnapshotRequest.zig");

pub const Result = @import("WorkspaceSnapshotResult.zig");

pub const Executor = @import("WorkspaceSnapshotExecutor.zig");

pub const Handler = @import("WorkspaceSnapshotHandler.zig");

test "Handler returns an existing workspace snapshot reference" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    var handler: Handler = .{ .workspaces = workspaces.reader() };

    const result = try handler.executor().execute(.{ .location = location });

    try std.testing.expectEqualDeep(location, result.location);
}

test "Handler rejects missing workspace identities" {
    var state: workspace_mod.State = .{};
    var workspaces = workspace_mod.Repository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    var handler: Handler = .{ .workspaces = workspaces.reader() };

    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .workspace = try schema.id.workspace(999) },
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .worktree = try schema.id.worktree(999) },
    }));
}
