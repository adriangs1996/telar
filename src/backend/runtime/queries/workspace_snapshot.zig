//! Application query for a workspace snapshot reference.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;

pub const Request = struct {
    location: schema.WorkspaceLocation,
};

pub const Result = struct {
    location: schema.WorkspaceLocation,
};

pub const Executor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, Request) anyerror!Result,

    /// Executes a workspace-snapshot query through its bound handler.
    ///
    /// ```zig
    /// const snapshot = try executor.execute(.{ .location = location });
    /// ```
    pub fn execute(executor: Executor, request: Request) !Result {
        return executor.execute_fn(executor.context, request);
    }
};

pub const Handler = struct {
    workspaces: workspace_mod.Reader,

    /// Returns a reference to an existing workspace. Pane and tab descriptors
    /// remain late-bound in the encoder so queued snapshots cannot own stale
    /// aggregate slices.
    ///
    /// ```zig
    /// const snapshot = try handler.execute(.{ .location = location });
    /// ```
    pub fn execute(handler: *Handler, request: Request) !Result {
        if (!handler.workspaces.containsWorkspace(request.location)) {
            return error.WorkspaceNotFound;
        }

        return .{ .location = request.location };
    }

    /// Exposes this handler through the query interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *Handler) Executor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, request: Request) !Result {
        const handler: *Handler = @ptrCast(@alignCast(context));
        return handler.execute(request);
    }
};

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
