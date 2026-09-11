const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const RenameWorkspaceExecutorType = @import("../../application/commands/RenameWorkspaceExecutor.zig");
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const RequestIdType = @import("telar-core").RequestId;
const RenameWorkspaceFailure = @import("RenameWorkspaceFailure.zig");
const Controller = @This();

responses: *ResponseQueueType,
rename_workspace: RenameWorkspaceExecutorType,

/// Creates a controller scoped to one workspace rename request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, rename_workspace: RenameWorkspaceExecutorType) Controller {
    return .{ .responses = responses, .rename_workspace = rename_workspace };
}

/// Maps a wire request into a rename command and queues the workspace
/// snapshot reference or the same protocol failures as the legacy flow.
///
/// ```zig
/// try controller.renameWorkspace(request);
/// ```
pub fn renameWorkspace(controller: *Controller, request: RenameWorkspaceType) !void {
    const renamed = controller.rename_workspace.execute(.{
        .location = request.workspace,
        .name = request.name,
    }) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try controller.queueFailure(request.request_id, .{
                .code = .workspace_not_found,
                .message = "workspace not found",
            }),
            error.InvalidWorkspaceName => try controller.queueFailure(request.request_id, .{
                .code = .internal,
                .message = "could not rename workspace",
            }),
            else => return err,
        }

        return;
    };

    try controller.responses.push(.{ .workspace_snapshot = .{
        .request_id = request.request_id,
        .workspace = renamed.location,
    } });
}

fn queueFailure(controller: *Controller, request_id: RequestIdType, failure: RenameWorkspaceFailure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
