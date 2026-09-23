//! A client asks to close a pane; the child's exit later retires it.

const core = @import("telar-core");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");

/// Requests closure of an attached pane. The pane stays until its exit.
///
/// ```zig
/// try pane_closure.close(session, request);
/// ```
pub fn close(session: *Session, request: core.ClosePane) !void {
    const attachment = session.attachments.find(request.pane_id) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane not attached");
    };

    _ = attachment.pane.requestClose();
}
