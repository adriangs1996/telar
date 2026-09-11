const ReaderType = @import("../../../workspace/Reader.zig");
const TabPanes = @import("TabPanes.zig");
const CreatePaneLaunchAuthority = @import("CreatePaneLaunchAuthority.zig");
const CreatePaneLauncher = @import("CreatePaneLauncher.zig");
const CreatePaneAttachment = @import("CreatePaneAttachment.zig");
const CreatePaneEventPublisher = @import("CreatePaneEventPublisher.zig");
const CreatePane = @import("CreatePane.zig");
const PaneLaunched = @import("../../../pane/PaneLaunched.zig");
const create_pane = @import("create_pane.zig");
const CreatePaneExecutor = @import("CreatePaneExecutor.zig");
const CreatePaneHandler = @This();

workspaces: ReaderType,
panes: TabPanes,
authority: CreatePaneLaunchAuthority,
launcher: CreatePaneLauncher,
attachment: CreatePaneAttachment,
events: CreatePaneEventPublisher,

/// Validates the live tab, resolves client launch authority, commits the
/// pane through `PaneLauncher`, then publishes and attaches it. Once launch
/// succeeds, later effect failures never withdraw the runtime-owned pane.
///
/// ```zig
/// const launched = try handler.execute(command);
/// ```
pub fn execute(handler: *CreatePaneHandler, command: CreatePane) !PaneLaunched {
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
    }) catch |err| return create_pane.mapLaunchError(err);

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

fn executeErased(context: *anyopaque, command: CreatePane) !PaneLaunched {
    const handler: *CreatePaneHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
