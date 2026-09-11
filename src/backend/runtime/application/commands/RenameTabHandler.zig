const RenameTabHandler = @This();
const source_namespace = @import("rename_tab.zig");
const EventPublisher = @import("RenameTabEventPublisher.zig");
const RenameTab = @import("RenameTab.zig");
const RenameTabExecutor = @import("RenameTabExecutor.zig");
workspaces: *source_namespace.WorkspaceRepository,
events: EventPublisher,

/// Resolves the aggregate, commits its rename, then publishes the owned
/// domain event. Failed commands neither mutate state nor publish events.
///
/// ```zig
/// const renamed = try handler.execute(.{ .location = location, .label = "server" });
/// ```
pub fn execute(handler: *RenameTabHandler, command: RenameTab) !source_namespace.RenameTabResult {
    const workspace = handler.workspaces.find(command.location.workspace) orelse return error.TabNotFound;
    const renamed = try workspace.renameTab(command.location.tab_id, command.label);

    handler.events.publish(handler.events.context, renamed);
    return renamed;
}

/// Erases the concrete handler behind the narrow command interface used
/// by request controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *RenameTabHandler) RenameTabExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: RenameTab) !source_namespace.RenameTabResult {
    const handler: *RenameTabHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
