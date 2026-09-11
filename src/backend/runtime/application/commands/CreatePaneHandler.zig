const CreatePaneHandler = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const TabPanes = @import("TabPanes.zig");
const LaunchAuthority = @import("CreatePaneLaunchAuthority.zig");
const PaneLauncher = @import("CreatePanePaneLauncher.zig");
const PaneAttachment = @import("CreatePanePaneAttachment.zig");
const EventPublisher = @import("CreatePaneEventPublisher.zig");
const CreatePane = @import("CreatePane.zig");
const source_namespace = @import("create_pane.zig");
const CreatePaneExecutor = @import("CreatePaneExecutor.zig");
workspaces: workspace_mod.Reader,
panes: TabPanes,
authority: LaunchAuthority,
launcher: PaneLauncher,
attachment: PaneAttachment,
events: EventPublisher,

/// Validates the live tab, resolves client launch authority, commits the
/// pane through `PaneLauncher`, then publishes and attaches it. Once launch
/// succeeds, later effect failures never withdraw the runtime-owned pane.
///
/// ```zig
/// const launched = try handler.execute(command);
/// ```
pub fn execute(handler: *CreatePaneHandler, command: CreatePane) !source_namespace.CreatePaneResult {
    if (!handler.workspaces.contains(command.location)) {
        return error.TabNotFound;
    }

    if (!handler.panes.has_running(handler.panes.context, command.location)) {
        return error.TabNotFound;
    }

    const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
        .location = command.location,
        .launch = command.launch,
    });
    const workspace_path = handler.workspaces.workspacePath(command.location.workspace) orelse return error.TabNotFound;
    const launched = handler.launcher.launch(handler.launcher.context, .{
        .location = command.location,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace_path,
    }) catch |err| return source_namespace.mapLaunchError(err);

    handler.events.publish(handler.events.context, launched);
    try handler.attachment.attach(handler.attachment.context, launched);
    return launched;
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *CreatePaneHandler) CreatePaneExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: CreatePane) !source_namespace.CreatePaneResult {
    const handler: *CreatePaneHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
