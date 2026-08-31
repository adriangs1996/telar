//! Disposable client resources keyed by pane identity.

const core = @import("telar-core");

const Client = @import("client.zig");
const schema = core.schema;

/// Releases copy, paste, focus and graphics state retained for one pane.
/// Repeated release is harmless.
///
/// ```zig
/// release(client, pane_id);
/// ```
pub fn release(client: *Client, pane_id: schema.PaneId) void {
    _ = client.model.releaseCopyMode(pane_id);
    _ = client.model.releasePanePaste(pane_id);

    if (client.reported_focus == pane_id) {
        client.forgetPaneFocus();
    }

    client.graphics_store.clearPane(pane_id);
}
