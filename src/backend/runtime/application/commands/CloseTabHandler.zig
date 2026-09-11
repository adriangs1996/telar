const CloseTabHandler = @This();
const source_namespace = @import("close_tab.zig");
const PaneCloser = @import("PaneCloser.zig");
const EventPublisher = @import("CloseTabEventPublisher.zig");
const CloseTab = @import("CloseTab.zig");
const workspace_mod = @import("../../../workspace/root.zig");
const CloseTabExecutor = @import("CloseTabExecutor.zig");
workspaces: *source_namespace.WorkspaceRepository,
panes: PaneCloser,
events: EventPublisher,

/// Commits one tab removal, starts closing its runtime panes, then
/// publishes the resulting domain fact. A missing tab has no effects.
/// Pane closure and event publication are infallible post-commit ports.
///
/// ```zig
/// const removed = try handler.execute(.{ .location = location });
/// ```
pub fn execute(handler: *CloseTabHandler, command: CloseTab) !source_namespace.CloseTabResult {
    const removed = workspace_mod.removeTab(handler.workspaces, command.location) orelse return error.TabNotFound;

    handler.panes.close_all(handler.panes.context, removed.location);
    handler.events.publish(handler.events.context, removed);
    return removed;
}

/// Erases the concrete handler behind the command interface consumed by
/// request controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *CloseTabHandler) CloseTabExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: CloseTab) !source_namespace.CloseTabResult {
    const handler: *CloseTabHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
