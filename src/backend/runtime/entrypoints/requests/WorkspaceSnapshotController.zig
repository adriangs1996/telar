const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const WorkspaceSnapshotExecutor = @import("../../application/queries/WorkspaceSnapshotExecutor.zig");
const RequestWorkspaceSnapshotType = @import("telar-core").RequestWorkspaceSnapshot;
const Controller = @This();

responses: *ResponseQueueType,
query: WorkspaceSnapshotExecutor,

/// Creates a controller scoped to one workspace-snapshot request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, query: WorkspaceSnapshotExecutor) Controller {
    return .{ .responses = responses, .query = query };
}

/// Maps a wire request to the workspace query and queues its canonical
/// reference or a `workspace_not_found` failure.
///
/// ```zig
/// try controller.requestWorkspaceSnapshot(request);
/// ```
pub fn requestWorkspaceSnapshot(controller: *Controller, request: RequestWorkspaceSnapshotType) !void {
    const snapshot = controller.query.execute(.{ .location = request.workspace }) catch |err| {
        if (err == error.WorkspaceNotFound) {
            try controller.responses.push(.{ .request_failed = .{
                .request_id = request.request_id,
                .code = .workspace_not_found,
                .message = "workspace not found",
            } });
            return;
        }

        return err;
    };

    try controller.responses.push(.{ .workspace_snapshot = .{
        .request_id = request.request_id,
        .workspace = snapshot.location,
    } });
}
