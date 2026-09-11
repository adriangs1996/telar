const Controller = @This();
const source_namespace = @import("workspace_snapshot.zig");
const workspace_snapshot_query = @import("../../application/queries/workspace_snapshot.zig");
responses: *source_namespace.ResponseQueue,
query: workspace_snapshot_query.Executor,

/// Creates a controller scoped to one workspace-snapshot request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, query: workspace_snapshot_query.Executor) Controller {
    return .{ .responses = responses, .query = query };
}

/// Maps a wire request to the workspace query and queues its canonical
/// reference or a `workspace_not_found` failure.
///
/// ```zig
/// try controller.requestWorkspaceSnapshot(request);
/// ```
pub fn requestWorkspaceSnapshot(controller: *Controller, request: source_namespace.schema.RequestWorkspaceSnapshot) !void {
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
