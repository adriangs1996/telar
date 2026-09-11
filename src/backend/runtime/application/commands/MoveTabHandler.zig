const Repository = @import("../../../workspace/Repository.zig");
const MoveTabEventPublisher = @import("MoveTabEventPublisher.zig");
const MoveTab = @import("MoveTab.zig");
const TabMoved = @import("../../../workspace/TabMoved.zig");
const commands = @import("../../../workspace/commands.zig");
const MoveTabExecutor = @import("MoveTabExecutor.zig");
const MoveTabHandler = @This();

workspaces: *Repository,
events: MoveTabEventPublisher,

/// Commits a move through the workspace aggregate and then publishes its
/// canonical position. Failed commands have no observable effects.
///
/// ```zig
/// const moved = try handler.execute(.{ .location = location, .direction = .previous });
/// ```
pub fn execute(handler: *MoveTabHandler, command: MoveTab) !TabMoved {
    const moved = try commands.moveTab(
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

fn executeErased(context: *anyopaque, command: MoveTab) !TabMoved {
    const handler: *MoveTabHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
