const CreateTabHandler = @This();
const source_namespace = @import("create_tab.zig");
const LaunchAuthority = @import("CreateTabLaunchAuthority.zig");
const PaneLauncher = @import("CreateTabPaneLauncher.zig");
const PaneAttachment = @import("CreateTabPaneAttachment.zig");
const EventPublisher = @import("CreateTabEventPublisher.zig");
const CreateTab = @import("CreateTab.zig");
const CreateTabResult = @import("CreateTabResult.zig");
const std = @import("std");
const CreateTabExecutor = @import("CreateTabExecutor.zig");
workspaces: *source_namespace.WorkspaceRepository,
authority: LaunchAuthority,
launcher: PaneLauncher,
attachment: PaneAttachment,
events: EventPublisher,

/// Creates a provisional aggregate tab, commits it only after its root
/// pane is running, publishes the committed event, then attaches the
/// requesting client. Pre-commit failures remove the provisional tab and
/// leave the identity cursor unchanged; post-commit failures never remove
/// runtime state.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *CreateTabHandler, command: CreateTab) !CreateTabResult {
    const workspace = handler.workspaces.find(command.workspace) orelse return error.WorkspaceNotFound;
    const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
        .workspace = command.workspace,
        .launch = command.launch,
    });
    const tab_id = try handler.workspaces.nextTabId();
    const created = try workspace.createTab(tab_id, command.label);
    var committed = false;

    defer if (!committed) {
        const removed = workspace.removeTab(tab_id);
        std.debug.assert(removed);
    };

    const launched = handler.launcher.launch(handler.launcher.context, .{
        .location = created.location,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace.pathSlice(),
    }) catch |err| return source_namespace.mapLaunchError(err);

    handler.workspaces.recordTabCreated(tab_id);
    committed = true;
    handler.events.publish(handler.events.context, created);
    try handler.attachment.attach(handler.attachment.context, launched);

    return .{
        .created = created,
        .root_pane_id = launched.id,
    };
}

/// Erases the concrete handler behind the command interface consumed by
/// request controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *CreateTabHandler) CreateTabExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: CreateTab) !CreateTabResult {
    const handler: *CreateTabHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
