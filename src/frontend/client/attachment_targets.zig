//! Synchronizes the focused agent's client-owned attachment shelf.

const Client = @import("client.zig");
const pane_geometry = @import("pane_geometry.zig");

/// Reconciles the focused attachment target and re-offers pane geometry when
/// the shelf changes the workbench.
///
/// ```zig
/// _ = try sync(client);
/// ```
pub fn sync(client: *Client) !bool {
    const changed = client.view.syncAttachmentTarget(client.model.focusedAttachmentTarget());
    if (!changed) {
        return false;
    }

    const active = client.model.workspace.active() orelse return true;
    try pane_geometry.offerAttached(client, &active.model, client.view.workbench());

    return true;
}
