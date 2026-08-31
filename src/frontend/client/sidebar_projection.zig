//! Projects committed sidebar visibility into disposable client resources.

const client_model = @import("model.zig");
const pane_geometry = @import("pane_geometry.zig");

const Client = @import("client.zig");

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
///
/// ```zig
/// try apply(client, change);
/// ```
pub fn apply(client: *Client, change: client_model.SidebarVisibility) !void {
    if (client.model.sidebarVisible() != change.visible or
        client.model.version().chrome != change.chrome_revision)
    {
        return error.UnexpectedSidebarVisibility;
    }

    client.view.setSidebarVisible(change.visible);
    client.graphics_store.invalidatePlacements();
    const active = client.model.workspace.active() orelse return;

    try pane_geometry.offerAttached(client, &active.model, client.view.workbench());
}
