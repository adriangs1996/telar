//! The geometry lease holder offers a pane size; the runtime resizes the
//! child, or defers the resize until the in-flight ingest completes.

const pane_graphics = @import("pane_graphics.zig");
const pane_observation = @import("pane_observation.zig");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const pane_closure = @import("pane_closure.zig");
const Session = @import("client/Session.zig");
const geometry_lease = @import("geometry_lease.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_input = @import("pane_input.zig");

/// Resizes an attached pane when the client holds its workspace's lease.
///
/// ```zig
/// try pane_resize.resize(model, session, request);
/// ```
pub fn resize(model: *RuntimeModel, session: *Session, request: core.PaneResize) !void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };
    const pane = attachment.pane;

    if (!geometry_lease.acquire(model, session.key, pane.location.workspace)) {
        model.metrics.geometry_rejections += 1;
        return;
    }

    try pane.requestResize(request.size);

    if (pane.ingest_pending) {
        return;
    }

    pane.applyPendingResize() catch {
        _ = pane_closure.requestClose(model, pane);
        return;
    };
    try pane_observation.start(model, pane);
    try pane_graphics.startMedia(model, pane);

    _ = attachment.resizeIfNeeded() catch {
        _ = pane_attachment.detachPane(model, session, request.pane_id);
        return;
    };

    try pane_input.startResponseWrite(model, pane);
}
