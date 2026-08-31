//! Synchronizes client-owned pane attachments during tab lifecycle changes.

const workspace_capability = @import("../workspace/root.zig");
const pane_pastes = @import("pane_pastes.zig");

const Client = @import("client.zig");
const tabs_mod = workspace_capability.tabs;

/// Finishes a captured paste, clears reported focus and then detaches every
/// attached or in-flight pane in protocol order.
///
/// ```zig
/// try detach(client, tab);
/// ```
pub fn detach(client: *Client, tab: *tabs_mod.Tab) !void {
    if (client.model.panePasteSession()) |session| {
        if (tab.model.findConst(session.pane_id) != null) {
            _ = try pane_pastes.finish(client);
        }
    }

    // Focus-out must leave before the pane detaches. Keeping both operations
    // here prevents callers from violating that protocol ordering.
    try client.clearPaneFocus();

    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        const attachment_pending = client.requests.hasPane(.attachment, pane.id);
        if (!pane.attached and !attachment_pending) {
            continue;
        }

        try client.enqueue(.{ .detach_pane = .{ .pane_id = pane.id } });
        _ = client.requests.ignoreAttachment(pane.id);
        try client.graphics_store.setPaneVisible(pane.id, false);
    }

    tabs_mod.Model.detachAll(tab);
}
