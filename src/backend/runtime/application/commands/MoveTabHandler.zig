const MoveTabHandler = @This();
const source_namespace = @import("move_tab.zig");
const EventPublisher = @import("MoveTabEventPublisher.zig");
const MoveTab = @import("MoveTab.zig");
const workspace_mod = @import("../../../workspace/root.zig");
const MoveTabExecutor = @import("MoveTabExecutor.zig");
workspaces: *source_namespace.WorkspaceRepository,
events: EventPublisher,

/// Commits a move through the workspace aggregate and then publishes its
/// canonical position. Failed commands have no observable effects.
///
/// ```zig
/// const moved = try handler.execute(.{ .location = location, .direction = .previous });
/// ```
pub fn execute(handler: *MoveTabHandler, command: MoveTab) !source_namespace.MoveTabResult {
    const moved = try workspace_mod.moveTab(
        handler.workspaces,
        command.location,
        command.direction,
    );

    handler.events.publish(handler.events.context, moved);
    return moved;
}

/// Exposes this handler through the command interface consumed by a
/// request-scoped controller.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *MoveTabHandler) MoveTabExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: MoveTab) !source_namespace.MoveTabResult {
    const handler: *MoveTabHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
