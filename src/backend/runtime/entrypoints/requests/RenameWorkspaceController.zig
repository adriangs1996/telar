const Controller = @This();
const source_namespace = @import("rename_workspace.zig");
const rename_workspace_commands = @import("../../application/commands/rename_workspace.zig");
const Failure = @import("RenameWorkspaceFailure.zig");
responses: *source_namespace.ResponseQueue,
rename_workspace: rename_workspace_commands.RenameWorkspaceExecutor,

/// Creates a controller scoped to one workspace rename request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, rename_workspace: rename_workspace_commands.RenameWorkspaceExecutor) Controller {
    return .{ .responses = responses, .rename_workspace = rename_workspace };
}

/// Maps a wire request into a rename command and queues the workspace
/// snapshot reference or the same protocol failures as the legacy flow.
///
/// ```zig
/// try controller.renameWorkspace(request);
/// ```
pub fn renameWorkspace(controller: *Controller, request: source_namespace.schema.RenameWorkspace) !void {
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

fn queueFailure(controller: *Controller, request_id: source_namespace.schema.RequestId, failure: Failure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
