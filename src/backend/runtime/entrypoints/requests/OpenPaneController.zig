const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const OpenPaneExecutorType = @import("../../application/commands/OpenPaneExecutor.zig");
const OpenPaneViewType = @import("telar-core").OpenPaneView;
const OpenPaneFailure = @import("OpenPaneFailure.zig");
const RequestIdType = @import("telar-core").RequestId;
const Controller = @This();

responses: *ResponseQueueType,
open_pane: OpenPaneExecutorType,

/// Creates a controller scoped to one open-pane request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, open_pane: OpenPaneExecutorType) Controller {
    return .{ .responses = responses, .open_pane = open_pane };
}

/// Maps a wire request into pane selection or launch and queues its
/// confirmation or one expected protocol failure.
///
/// ```zig
/// try controller.openPane(request);
/// ```
pub fn openPane(controller: *Controller, request: OpenPaneViewType) !void {
    const result = controller.open_pane.execute(.{
        .target = request.target,
        .size = request.size,
        .launch = request.launch,
    }) catch |err| {
        const failure: OpenPaneFailure = switch (err) {
            error.PaneNotFound => .{ .code = .pane_not_found, .message = "pane not found" },
            error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
            error.WorkspaceHasNoPane => .{ .code = .pane_not_found, .message = "workspace has no running pane" },
            error.InvalidOpenRequest => .{ .code = .invalid_request, .message = "default pane launch is missing" },
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            error.PaneResizeFailed => .{ .code = .internal, .message = "could not resize pane" },
            else => return err,
        };

        try controller.queueFailure(request.request_id, failure);
        return;
    };

    try controller.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = result.pane.key.id,
        .location = result.pane.location,
        .created = result.created,
    } });
}

fn queueFailure(controller: *Controller, request_id: RequestIdType, failure: OpenPaneFailure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
