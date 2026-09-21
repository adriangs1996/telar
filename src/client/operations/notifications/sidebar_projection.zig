//! Projects committed sidebar visibility into disposable client resources.

const Client = @import("../../AttachedClient.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
///
/// ```zig
/// try apply(client, change);
/// ```
pub fn apply(client: *Client, change: SidebarLayoutType) !void {
    if (client.model.sidebarVisible() != change.visible or client.model.sidebarWidth() != change.width or
        client.model.version().chrome != change.chrome_revision)
    {
        return error.StaleSidebarLayout;
    }

    client.chrome.setSidebarLayout(change.visible, change.width);
    client.host_graphics.invalidatePlacements();
    const active = client.model.workspace.active() orelse return;
    try pane_geometry.offerAttached(client, &active.model, client.geometry().area);
}
