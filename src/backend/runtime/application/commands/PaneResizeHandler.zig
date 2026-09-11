const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const PaneResizeGeometryLease = @import("PaneResizeGeometryLease.zig");
const PaneResizeScheduler = @import("PaneResizeScheduler.zig");
const PaneResize = @import("PaneResize.zig");
const pane_resize = @import("pane_resize.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const PaneResizeHandler = @This();

attachments: *AttachmentStoreType,
geometry: PaneResizeGeometryLease,
scheduler: PaneResizeScheduler,

/// Applies an authorized resize immediately while ingestion is idle, then
/// synchronizes observation, media, and the client's cell buffers in that
/// order. An active ingest keeps the resize pending for its completion
/// handler. Local pane resize failure closes the pane; attachment allocation
/// failure detaches only this client's disposable projection.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id, .size = size });
/// ```
pub fn execute(handler: *PaneResizeHandler, command: PaneResize) !pane_resize.PaneResizeResult {
    const attachment = handler.attachments.find(command.pane_id) orelse return .pane_not_attached;
    const pane = attachment.pane;

    if (!handler.geometry.holds(handler.geometry.context, pane.location.workspace)) {
        return .geometry_rejected;
    }

    try pane.requestResize(command.size);

    if (pane.ingest_pending) {
        return .handled;
    }

    pane.applyPendingResize() catch {
        _ = pane.requestClose();
        return .handled;
    };
    try handler.scheduler.observation(handler.scheduler.context, pane);
    try handler.scheduler.media(handler.scheduler.context, pane);

    _ = attachment.resizeIfNeeded() catch {
        handler.detachFailedProjection(command.pane_id);
        return .handled;
    };

    try handler.scheduler.response(handler.scheduler.context, pane);
    return .handled;
}

fn detachFailedProjection(handler: *PaneResizeHandler, pane_id: PaneIdType) void {
    const detached = handler.attachments.detach(pane_id) orelse return;

    if (!detached.last_attachment) {
        return;
    }

    const left_workspace = handler.attachments.leaveWorkspace(detached.workspace);
    std.debug.assert(left_workspace);

    if (left_workspace) {
        handler.geometry.release(handler.geometry.context, detached.workspace);
    }
}
