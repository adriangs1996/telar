const Controller = @This();
const source_namespace = @import("create_tab.zig");
const create_tab_commands = @import("../../application/commands/create_tab.zig");
const Failure = @import("CreateTabFailure.zig");
responses: *source_namespace.ResponseQueue,
create_tab: create_tab_commands.CreateTabExecutor,

/// Creates one controller for the lifetime of a create-tab request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor());
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, create_tab: create_tab_commands.CreateTabExecutor) Controller {
    return .{ .responses = responses, .create_tab = create_tab };
}

/// Translates the wire request into an application command and maps its
/// result or expected failure into exactly one client response.
///
/// ```zig
/// try controller.createTab(request);
/// ```
pub fn createTab(controller: *Controller, request: source_namespace.schema.CreateTabView) !void {
    const result = controller.create_tab.execute(.{
        .workspace = request.workspace,
        .label = request.label,
        .size = request.size,
        .launch = request.launch,
    }) catch |err| {
        const failure: Failure = switch (err) {
            error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
            error.TabLimitReached => .{ .code = .resource_limit, .message = "tab limit reached" },
            error.InvalidTabLabel => .{ .code = .invalid_request, .message = "invalid tab label" },
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

    const label = result.created.labelSlice();
    var pending: source_namespace.PendingTabCreated = .{
        .request_id = request.request_id,
        .location = result.created.location,
        .position = result.created.position,
        .label = undefined,
        .label_len = @intCast(label.len),
        .root_pane_id = result.root_pane_id,
    };
    @memcpy(pending.label[0..label.len], label);
    try controller.responses.push(.{ .tab_created = pending });
}

fn queueFailure(controller: *Controller, request_id: source_namespace.schema.RequestId, failure: Failure) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}
