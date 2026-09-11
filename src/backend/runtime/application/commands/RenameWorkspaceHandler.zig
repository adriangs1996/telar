const RenameWorkspaceHandler = @This();
const source_namespace = @import("rename_workspace.zig");
const EventPublisher = @import("RenameWorkspaceEventPublisher.zig");
const RenameWorkspace = @import("RenameWorkspace.zig");
const workspace_mod = @import("../../../workspace/root.zig");
const RenameWorkspaceExecutor = @import("RenameWorkspaceExecutor.zig");
workspaces: *source_namespace.WorkspaceRepository,
events: EventPublisher,

/// Commits an aggregate rename and repository revision before publishing
/// the owned workspace event. Failed commands have no effects.
///
/// ```zig
/// const renamed = try handler.execute(.{ .location = location, .name = "backend" });
/// ```
pub fn execute(handler: *RenameWorkspaceHandler, command: RenameWorkspace) !source_namespace.RenameWorkspaceResult {
    const renamed = try workspace_mod.renameWorkspace(
        handler.workspaces,
        command.location,
        command.name,
    );

    handler.events.publish(handler.events.context, renamed);
    return renamed;
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *RenameWorkspaceHandler) RenameWorkspaceExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: RenameWorkspace) !source_namespace.RenameWorkspaceResult {
    const handler: *RenameWorkspaceHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
