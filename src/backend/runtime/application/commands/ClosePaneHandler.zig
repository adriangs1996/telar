const AttachedPaneCloser = @import("AttachedPaneCloser.zig");
const ClosePane = @import("ClosePane.zig");
const ClosePaneResult = @import("ClosePaneResult.zig");
const ClosePaneExecutor = @import("ClosePaneExecutor.zig");
const ClosePaneHandler = @This();

panes: AttachedPaneCloser,

/// Authorizes the pane through the requesting client's attachments and
/// requests its idempotent PTY shutdown. Actual retirement happens later.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *ClosePaneHandler, command: ClosePane) !ClosePaneResult {
    const newly_requested = handler.panes.request_close(
        handler.panes.context,
        command.pane_id,
    ) orelse return error.PaneNotAttached;

    return .{
        .pane_id = command.pane_id,
        .newly_requested = newly_requested,
    };
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *ClosePaneHandler) ClosePaneExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: ClosePane) !ClosePaneResult {
    const handler: *ClosePaneHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
