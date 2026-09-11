const Controller = @This();
const source_namespace = @import("create_workspace.zig");
const create_workspace_commands = @import("../../application/commands/create_workspace.zig");
const Failure = @import("CreateWorkspaceFailure.zig");
responses: *source_namespace.ResponseQueue,
create_workspace: create_workspace_commands.CreateWorkspaceExecutor,

/// Creates a controller scoped to one create-workspace request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, create_workspace: create_workspace_commands.CreateWorkspaceExecutor) Controller {
    return .{ .responses = responses, .create_workspace = create_workspace };
}

/// Maps the wire request into a creation transaction and queues its root
/// pane confirmation or one expected protocol failure.
///
/// ```zig
/// try controller.createWorkspace(request);
/// ```
pub fn createWorkspace(controller: *Controller, request: source_namespace.schema.CreateWorkspaceView) !void {
    const result = controller.create_workspace.execute(.{
        .name = request.name,
        .size = request.size,
        .launch = request.launch,
    }) catch |err| {
        const failure: Failure = switch (err) {
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is unavailable" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            else => return err,
        };

        try controller.queueFailure(request.request_id, failure);
        return;
    };

    try controller.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = result.root_pane_id,
        .location = result.created.location,
        .created = true,
    } });
}

fn queueFailure(controller: *Controller, request_id: source_namespace.schema.RequestId, failure: Failure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
