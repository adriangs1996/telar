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
    const attachment = model.attachments.find(session.slot, viewport.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    _ = try attachment.setViewport(viewport.offset);
}
