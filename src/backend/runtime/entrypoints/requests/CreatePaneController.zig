const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const CreatePaneExecutorType = @import("../../application/commands/CreatePaneExecutor.zig");
const CreatePaneViewType = @import("telar-core").CreatePaneView;
const CreatePaneFailure = @import("CreatePaneFailure.zig");
const RequestIdType = @import("telar-core").RequestId;
const Controller = @This();

responses: *ResponseQueueType,
create_pane: CreatePaneExecutorType,

/// Creates a controller scoped to one create-pane request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *ResponseQueueType, create_pane: CreatePaneExecutorType) Controller {
    return .{ .responses = responses, .create_pane = create_pane };
}

/// Maps a wire request into a pane launch and queues its confirmation or
/// one expected protocol failure.
///
/// ```zig
/// try controller.createPane(request);
/// ```
pub fn createPane(controller: *Controller, request: CreatePaneViewType) !void {
    const launched = controller.create_pane.execute(.{
        .location = request.location,
        .size = request.size,
        .launch = request.launch,
    }) catch |err| {
        const failure: CreatePaneFailure = switch (err) {
            error.TabNotFound => .{ .code = .pane_not_found, .message = "tab not found" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
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
        .pane_id = launched.key.id,
        .location = launched.location,
        .created = true,
    } });
}

fn queueFailure(controller: *Controller, request_id: RequestIdType, failure: CreatePaneFailure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
