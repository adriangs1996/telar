const Repository = @import("../../../workspace/Repository.zig");
const RenameWorkspaceEventPublisher = @import("RenameWorkspaceEventPublisher.zig");
const RenameWorkspace = @import("RenameWorkspace.zig");
const WorkspaceRenamed = @import("../../../workspace/WorkspaceRenamed.zig");
const commands = @import("../../../workspace/commands.zig");
const RenameWorkspaceExecutor = @import("RenameWorkspaceExecutor.zig");
const RenameWorkspaceHandler = @This();

workspaces: *Repository,
events: RenameWorkspaceEventPublisher,

/// Commits an aggregate rename and repository revision before publishing
/// the owned workspace event. Failed commands have no effects.
///
/// ```zig
/// const renamed = try handler.execute(.{ .location = location, .name = "backend" });
/// ```
pub fn execute(handler: *RenameWorkspaceHandler, command: RenameWorkspace) !WorkspaceRenamed {
    const renamed = try commands.renameWorkspace(
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

fn executeErased(context: *anyopaque, command: RenameWorkspace) !WorkspaceRenamed {
    const handler: *RenameWorkspaceHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
