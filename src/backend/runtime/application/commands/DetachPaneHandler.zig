const Attachments = @import("Attachments.zig");
const DetachPaneGeometryLease = @import("DetachPaneGeometryLease.zig");
const DetachPane = @import("DetachPane.zig");
const detach_pane = @import("detach_pane.zig");
const std = @import("std");
const DetachPaneExecutor = @import("DetachPaneExecutor.zig");
const DetachPaneHandler = @This();

attachments: Attachments,
geometry: DetachPaneGeometryLease,

/// Commits attachment removal, ends empty-workspace observation, then
/// releases its geometry. Missing attachments have no effect.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *DetachPaneHandler, command: DetachPane) !detach_pane.DetachPaneResult {
    const detached = handler.attachments.detach(handler.attachments.context, command.pane_id) orelse return .not_attached;
    std.debug.assert(detached.pane_id == command.pane_id);

    if (detached.last_attachment) {
        const left_workspace = handler.attachments.leave_workspace(handler.attachments.context, detached.workspace);

        if (!left_workspace) {
            return error.AttachmentStateConflict;
        }

        handler.geometry.release(handler.geometry.context, detached.workspace);
    }

    return .detached;
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *DetachPaneHandler) DetachPaneExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: DetachPane) !detach_pane.DetachPaneResult {
    const handler: *DetachPaneHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
