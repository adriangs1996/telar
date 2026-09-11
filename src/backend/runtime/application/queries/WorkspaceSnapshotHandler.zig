const Handler = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const Request = @import("WorkspaceSnapshotRequest.zig");
const Result = @import("WorkspaceSnapshotResult.zig");
const Executor = @import("WorkspaceSnapshotExecutor.zig");
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
