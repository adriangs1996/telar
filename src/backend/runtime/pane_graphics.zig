//! A client controls its graphics projection of attached panes: snapshot
//! recovery, returned transfer credit and the transport policy.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");

/// Replaces the client's graphics baseline for one pane.
///
/// ```zig
/// pane_graphics.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestGraphicsSnapshot) void {
    if (!session.attachments.requestGraphicsSnapshot(request.pane_id)) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Returns graphics bytes the client consumed from one attachment.
///
/// ```zig
/// pane_graphics.returnCredit(model, session, credit);
/// ```
pub fn returnCredit(model: *RuntimeModel, session: *Session, credit: core.GraphicsCredit) void {
    if (session.attachments.returnGraphicsCredit(credit) != .returned) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Selects shared-memory or inline graphics transport for the client.
///
/// ```zig
/// pane_graphics.configure(session, request);
/// ```
pub fn configure(session: *Session, request: core.ConfigureGraphics) void {
    _ = session.attachments.configureGraphics(request.shared);
}
