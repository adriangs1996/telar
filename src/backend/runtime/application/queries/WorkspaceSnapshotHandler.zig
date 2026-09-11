const ReaderType = @import("../../../workspace/Reader.zig");
const WorkspaceSnapshotRequest = @import("WorkspaceSnapshotRequest.zig");
const WorkspaceSnapshotResult = @import("WorkspaceSnapshotResult.zig");
const WorkspaceSnapshotExecutor = @import("WorkspaceSnapshotExecutor.zig");
const Handler = @This();

workspaces: ReaderType,

/// Returns a reference to an existing workspace. Pane and tab descriptors
/// remain late-bound in the encoder so queued snapshots cannot own stale
/// aggregate slices.
///
/// ```zig
/// const snapshot = try handler.execute(.{ .location = location });
/// ```
pub fn execute(handler: *Handler, request: WorkspaceSnapshotRequest) !WorkspaceSnapshotResult {
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
pub fn executor(handler: *Handler) WorkspaceSnapshotExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, request: WorkspaceSnapshotRequest) !WorkspaceSnapshotResult {
    const handler: *Handler = @ptrCast(@alignCast(context));
    return handler.execute(request);
}
