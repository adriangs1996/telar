//! A client scrolls its view of an attached pane's retained output.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");

/// Moves the client's viewport over the pane's scrollback.
///
/// ```zig
/// try pane_viewport.scroll(model, session, viewport);
/// ```
pub fn scroll(model: *RuntimeModel, session: *Session, viewport: core.SetPaneViewport) !void {
    if (try session.attachments.setPaneViewport(viewport) == null) {
        model.metrics.stale_client_messages += 1;
    }
}
